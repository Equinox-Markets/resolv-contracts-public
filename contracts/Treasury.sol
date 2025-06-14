// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlDefaultAdminRulesUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAaveTreasuryConnector} from "./interfaces/IAaveTreasuryConnector.sol";
import {ISiloTreasuryConnector} from "./interfaces/ISiloTreasuryConnector.sol";
import {IEulerTreasuryConnector} from "./interfaces/IEulerTreasuryConnector.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IAddressesWhitelist} from "./interfaces/IAddressesWhitelist.sol";
import {ISimpleToken} from "./interfaces/ISimpleToken.sol";
import {IChainlinkOracle} from "./interfaces/oracles/IChainlinkOracle.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";

contract Treasury is ITreasury, AccessControlDefaultAdminRulesUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {

    using Address for address payable;
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant SERVICE_ROLE = keccak256("SERVICE_ROLE");
    bytes32 public constant REDEMPTION_ROLE = keccak256("REDEMPTION_ROLE");

    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant USDX_DECIMALS = 18;
    uint256 public constant PRICE_SCALE = 1e18;
    uint256 public constant HEARTBEAT_INTERVAL = 86400; // 24 hours

    address public immutable USDX_ADDRESS;
    address public immutable USDC_ADDRESS;

    uint16 public aaveReferralCode;
    IAaveTreasuryConnector public aaveTreasuryConnector;
    ISiloTreasuryConnector public siloTreasuryConnector;
    IEulerTreasuryConnector public eulerTreasuryConnector;
    IChainlinkOracle public chainlinkOracle;
    IEscrow public escrow;

    IAddressesWhitelist public recipientWhitelist;
    bool public isRecipientWhitelistEnabled;
    IAddressesWhitelist public spenderWhitelist;
    bool public isSpenderWhitelistEnabled;

    // Redemption state
    mapping(address user => mapping(address asset => uint256 amount)) public pendingRedemptions;
    mapping(address user => mapping(address asset => uint256 timestamp)) public userCooldowns;
    mapping(uint256 blockNumber => uint256 amount) public redeemedPerBlock;
    mapping(address asset => bool isRedeemable) public redeemableAssets;
    
    uint256 public cooldownDuration;
    uint256 public maxRedeemPerBlock;

    // Vault configurations for withdrawal prioritization
    struct VaultConfig {
        address vault;
        address connector;
        uint256 allocation;
        bool isActive;
    }
    
    VaultConfig[] public siloVaults;
    VaultConfig[] public eulerVaults;

    mapping(OperationType operation => mapping(bytes32 idempotencyKey => bool exist)) public operationRegistry;
    mapping(OperationType operation => uint256 limit) public operationLimits;

    modifier idempotent(OperationType _operation, bytes32 _idempotencyKey) {
        if (operationRegistry[_operation][_idempotencyKey]) {
            revert IdempotencyKeyAlreadyExist(_idempotencyKey);
        }
        _;
        operationRegistry[_operation][_idempotencyKey] = true;
    }

    modifier onlyAllowedRecipient(address _recipient) {
        if (isRecipientWhitelistEnabled && !recipientWhitelist.isAllowedAccount(_recipient)) {
            revert UnknownRecipient(_recipient);
        }
        _;
    }

    modifier onlyAllowedSpender(address _spender) {
        if (isSpenderWhitelistEnabled && !spenderWhitelist.isAllowedAccount(_spender)) {
            revert UnknownSpender(_spender);
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _usdxAddress, address _usdcAddress) {
        USDX_ADDRESS = _assertNonZero(_usdxAddress);
        USDC_ADDRESS = _assertNonZero(_usdcAddress);
        _disableInitializers();
    }

    function initialize(
        address _aaveTreasuryConnector,
        address _siloTreasuryConnector,
        address _eulerTreasuryConnector,
        address _recipientWhitelist,
        address _spenderWhitelist,
        address _chainlinkOracle,
        address _escrow,
        uint256 _cooldownDuration,
        uint256 _maxRedeemPerBlock
    ) public initializer {
        __AccessControlDefaultAdminRules_init(1 days, msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();

        // Initialize operation limits
        operationLimits[OperationType.AaveSupply] = type(uint256).max;
        operationLimits[OperationType.AaveBorrow] = type(uint256).max;
        operationLimits[OperationType.AaveWithdraw] = type(uint256).max;
        operationLimits[OperationType.AaveRepay] = type(uint256).max;
        operationLimits[OperationType.SiloDeposit] = type(uint256).max;
        operationLimits[OperationType.SiloWithdraw] = type(uint256).max;
        operationLimits[OperationType.EulerDeposit] = type(uint256).max;
        operationLimits[OperationType.EulerWithdraw] = type(uint256).max;
        operationLimits[OperationType.EulerEnableCollateral] = type(uint256).max;
        operationLimits[OperationType.EulerDisableCollateral] = type(uint256).max;
        operationLimits[OperationType.TransferETH] = type(uint256).max;
        operationLimits[OperationType.TransferERC20] = type(uint256).max;
        operationLimits[OperationType.IncreaseAllowance] = type(uint256).max;
        operationLimits[OperationType.DecreaseAllowance] = type(uint256).max;
        operationLimits[OperationType.InitiateRedemption] = type(uint256).max;

        // Initialize connectors
        _assertNonZero(_aaveTreasuryConnector);
        aaveTreasuryConnector = IAaveTreasuryConnector(_aaveTreasuryConnector);
        aaveReferralCode = 0;

        _assertNonZero(_siloTreasuryConnector);
        siloTreasuryConnector = ISiloTreasuryConnector(_siloTreasuryConnector);

        _assertNonZero(_eulerTreasuryConnector);
        eulerTreasuryConnector = IEulerTreasuryConnector(_eulerTreasuryConnector);

        // Initialize oracle and escrow
        chainlinkOracle = IChainlinkOracle(_assertNonZero(_chainlinkOracle));
        escrow = IEscrow(_assertNonZero(_escrow));

        // Initialize whitelists
        _assertNonZero(_recipientWhitelist);
        recipientWhitelist = IAddressesWhitelist(_recipientWhitelist);
        isRecipientWhitelistEnabled = true;

        _assertNonZero(_spenderWhitelist);
        spenderWhitelist = IAddressesWhitelist(_spenderWhitelist);
        isSpenderWhitelistEnabled = true;

        // Initialize redemption parameters
        cooldownDuration = _cooldownDuration;
        maxRedeemPerBlock = _maxRedeemPerBlock;
        
        // USDC is redeemable by default
        redeemableAssets[USDC_ADDRESS] = true;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    // =============================================================================
    // REDEMPTION SYSTEM
    // =============================================================================

    /**
     * @dev Initiates redemption of USDX for USDC with cooldown period
     * @param _usdxAmount Amount of USDX to redeem
     * @param _minUsdcAmount Minimum USDC amount expected
     * @return usdxAmount The USDX amount burned
     * @return usdcAmount The USDC amount to be received after cooldown
     */
    function initiateRedemption(
        uint256 _usdxAmount,
        uint256 _minUsdcAmount
    ) external 
        whenNotPaused 
        nonReentrant 
        returns (uint256 usdxAmount, uint256 usdcAmount) 
    {
        if (!redeemableAssets[USDC_ADDRESS]) revert UnsupportedAsset();
        if (_usdxAmount == 0) revert InvalidAmount(_usdxAmount);

        // Calculate USDC amount using price adjustment
        usdcAmount = computeRedemption(USDC_ADDRESS, _usdxAmount);
        if (usdcAmount < _minUsdcAmount) revert MinimumCollateralAmountNotMet();

        // Track pending redemption and start cooldown
        pendingRedemptions[msg.sender][USDC_ADDRESS] += usdcAmount;
        userCooldowns[msg.sender][USDC_ADDRESS] = block.timestamp;
        redeemedPerBlock[block.number] += _usdxAmount;

        // Check block limits
        if (redeemedPerBlock[block.number] > maxRedeemPerBlock) {
            revert ExceedsMaxBlockLimit();
        }

        // Burn USDX immediately
        ISimpleToken(USDX_ADDRESS).burn(msg.sender, _usdxAmount);

        // Ensure enough USDC is available
        uint256 availableUsdc = IERC20(USDC_ADDRESS).balanceOf(address(this));
        if (availableUsdc < usdcAmount) {
            uint256 toWithdraw = usdcAmount - availableUsdc;
            _withdrawFromProtocols(toWithdraw);
        }

        // Move USDC to escrow during cooldown
        IERC20(USDC_ADDRESS).safeTransfer(address(escrow), usdcAmount);

        emit RedemptionInitiated(msg.sender, USDC_ADDRESS, usdcAmount, _usdxAmount);

        return (_usdxAmount, usdcAmount);
    }

    /**
     * @dev Completes redemption after cooldown period
     * @param _beneficiary Address to receive the USDC
     * @return usdcAmount Amount of USDC transferred
     */
    function completeRedemption(
        address _beneficiary
    ) external 
        whenNotPaused 
        nonReentrant 
        returns (uint256 usdcAmount) 
    {
        // Check cooldown has passed
        if (userCooldowns[msg.sender][USDC_ADDRESS] + cooldownDuration > block.timestamp) {
            revert StillInCooldown();
        }

        // Get pending redemption amount
        usdcAmount = pendingRedemptions[msg.sender][USDC_ADDRESS];
        if (usdcAmount == 0) revert NoPendingRedemptions();

        // Clear redemption state
        userCooldowns[msg.sender][USDC_ADDRESS] = 0;
        pendingRedemptions[msg.sender][USDC_ADDRESS] = 0;

        // Transfer USDC from escrow to beneficiary
        escrow.withdraw(_beneficiary, USDC_ADDRESS, usdcAmount);

        emit RedemptionCompleted(msg.sender, _beneficiary, USDC_ADDRESS, usdcAmount);

        return usdcAmount;
    }

    /**
     * @dev Computes USDC amount for USDX redemption with price adjustment
     * @param _asset The asset to redeem (USDC)
     * @param _usdxAmount Amount of USDX to redeem
     * @return usdcAmount Amount of USDC to receive
     */
    function computeRedemption(
        address _asset,
        uint256 _usdxAmount
    ) public view returns (uint256 usdcAmount) {
        if (_asset != USDC_ADDRESS) revert UnsupportedAsset();

        try chainlinkOracle.getLatestRoundData(USDC_ADDRESS) returns (
            uint80, int256 price, uint256, uint256 updatedAt, uint80
        ) {
            // Check if price data is recent
            if (block.timestamp - updatedAt > HEARTBEAT_INTERVAL) {
                // Use 1:1 conversion if stale data
                return _convertUsdxToUsdc(_usdxAmount);
            }

            uint8 priceDecimals = chainlinkOracle.priceDecimals(USDC_ADDRESS);
            uint256 priceScale = 10 ** priceDecimals;

            // If USDC is trading above $1, give less USDC to maintain collateralization
            if (uint256(price) > priceScale) {
                uint256 adjustedUsdxAmount = _usdxAmount.mulDiv(priceScale, uint256(price));
                return _convertUsdxToUsdc(adjustedUsdxAmount);
            } else {
                // 1:1 conversion (1 USDX = 1 USDC)
                return _convertUsdxToUsdc(_usdxAmount);
            }
        } catch {
            // Fallback to 1:1 conversion if oracle fails
            return _convertUsdxToUsdc(_usdxAmount);
        }
    }

    /**
     * @dev Withdraws USDC from lending protocols to fulfill redemption
     * @param _amount Amount of USDC needed
     */
    function _withdrawFromProtocols(uint256 _amount) internal {
        uint256 remaining = _amount;

        // Try withdrawing from Silo vaults first (60% allocation)
        for (uint256 i = 0; i < siloVaults.length && remaining > 0; i++) {
            if (!siloVaults[i].isActive) continue;
            
            uint256 vaultBalance = siloTreasuryConnector.getVaultBalance(siloVaults[i].vault);
            if (vaultBalance == 0) continue;

            uint256 maxWithdraw = siloTreasuryConnector.previewWithdraw(siloVaults[i].vault, remaining);
            
            if (maxWithdraw > 0) {
                uint256 toWithdraw = remaining > maxWithdraw ? maxWithdraw : remaining;
                siloTreasuryConnector.withdraw(USDC_ADDRESS, siloVaults[i].vault, toWithdraw);
                remaining -= toWithdraw;
            }
        }

        // Then try Euler vaults (40% allocation)
        for (uint256 i = 0; i < eulerVaults.length && remaining > 0; i++) {
            if (!eulerVaults[i].isActive) continue;
            
            uint256 vaultBalance = eulerTreasuryConnector.getVaultBalance(eulerVaults[i].vault);
            if (vaultBalance == 0) continue;

            uint256 maxWithdraw = eulerTreasuryConnector.previewWithdraw(eulerVaults[i].vault, remaining);
            
            if (maxWithdraw > 0) {
                uint256 toWithdraw = remaining > maxWithdraw ? maxWithdraw : remaining;
                eulerTreasuryConnector.withdraw(USDC_ADDRESS, eulerVaults[i].vault, toWithdraw);
                remaining -= toWithdraw;
            }
        }

        // Finally try Aave if still need more
        if (remaining > 0) {
            uint256 aaveBalance = aaveTreasuryConnector.getATokenBalance(USDC_ADDRESS);
            if (aaveBalance > 0) {
                uint256 toWithdraw = remaining > aaveBalance ? aaveBalance : remaining;
                aaveTreasuryConnector.withdraw(USDC_ADDRESS, toWithdraw);
                remaining -= toWithdraw;
            }
        }

        if (remaining > 0) {
            revert InsufficientLiquidity();
        }
    }

    /**
     * @dev Converts USDX amount to USDC amount accounting for decimals
     * @param _usdxAmount Amount in USDX (18 decimals)
     * @return usdcAmount Amount in USDC (6 decimals)
     */
    function _convertUsdxToUsdc(uint256 _usdxAmount) internal pure returns (uint256 usdcAmount) {
        return _usdxAmount / (10 ** (USDX_DECIMALS - USDC_DECIMALS));
    }

    // =============================================================================
    // BASIC TREASURY OPERATIONS
    // =============================================================================

    function setOperationLimit(
        OperationType _operation,
        uint256 _limit
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        operationLimits[_operation] = _limit;

        emit OperationLimitSet(_operation, _limit);
    }

    function setRecipientWhitelistEnabled(bool _isEnabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isRecipientWhitelistEnabled = _isEnabled;

        emit RecipientWhitelistEnabledSet(_isEnabled);
    }

    function setRecipientWhitelist(address _recipientWhitelist) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_recipientWhitelist);
        if (_recipientWhitelist.code.length == 0) revert InvalidRecipientWhitelist(_recipientWhitelist);

        recipientWhitelist = IAddressesWhitelist(_recipientWhitelist);

        emit RecipientWhitelistSet(_recipientWhitelist);
    }

    function setSpenderWhitelistEnabled(bool _isEnabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isSpenderWhitelistEnabled = _isEnabled;

        emit SpenderWhitelistEnabledSet(_isEnabled);
    }

    function setSpenderWhitelist(address _spenderWhitelist) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_spenderWhitelist);
        if (_spenderWhitelist.code.length == 0) revert InvalidSpenderWhitelist(_spenderWhitelist);

        spenderWhitelist = IAddressesWhitelist(_spenderWhitelist);

        emit SpenderWhitelistSet(_spenderWhitelist);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function transferETH(
        bytes32 _idempotencyKey,
        address payable _to,
        uint256 _amount
    ) external onlyRole(SERVICE_ROLE) idempotent(OperationType.TransferETH, _idempotencyKey) onlyAllowedRecipient(_to) {
        if (paused()) {
            _checkRole(DEFAULT_ADMIN_ROLE);
        }

        _assertNonZero(_to);
        _assertNonZero(_amount);
        _assertSufficientFunds(_amount);
        _assertOperationLimit(OperationType.TransferETH, _amount);

        _to.sendValue(_amount);

        emit TransferredETH(_idempotencyKey, _to, _amount);
    }

    function transferERC20(
        bytes32 _idempotencyKey,
        IERC20 _token,
        address _to,
        uint256 _amount
    ) external onlyRole(SERVICE_ROLE) idempotent(OperationType.TransferERC20, _idempotencyKey) onlyAllowedRecipient(_to) {
        if (paused()) {
            _checkRole(DEFAULT_ADMIN_ROLE);
        }

        _assertNonZero(address(_token));
        _assertNonZero(_to);
        _assertNonZero(_amount);
        _assertOperationLimit(OperationType.TransferERC20, _amount);

        _token.safeTransfer(_to, _amount);

        emit TransferredERC20(_idempotencyKey, address(_token), _to, _amount);
    }

    function increaseAllowance(
        bytes32 _idempotencyKey,
        IERC20 _token,
        address _spender,
        uint256 _increaseAmount
    ) external onlyRole(SERVICE_ROLE) idempotent(OperationType.IncreaseAllowance, _idempotencyKey) onlyAllowedSpender(_spender) whenNotPaused {
        _assertNonZero(address(_token));
        _assertNonZero(_spender);
        _assertNonZero(_increaseAmount);
        _assertOperationLimit(OperationType.IncreaseAllowance, _increaseAmount);

        _token.safeIncreaseAllowance(_spender, _increaseAmount);

        emit IncreasedAllowance(_idempotencyKey, address(_token), _spender, _increaseAmount);
    }

    function decreaseAllowance(
        bytes32 _idempotencyKey,
        IERC20 _token,
        address _spender,
        uint256 _decreaseAmount
    ) external onlyRole(SERVICE_ROLE) idempotent(OperationType.DecreaseAllowance, _idempotencyKey) whenNotPaused {
        _assertNonZero(address(_token));
        _assertNonZero(_spender);
        _assertNonZero(_decreaseAmount);
        _assertOperationLimit(OperationType.DecreaseAllowance, _decreaseAmount);

        _token.safeDecreaseAllowance(_spender, _decreaseAmount);

        emit DecreasedAllowance(_idempotencyKey, address(_token), _spender, _decreaseAmount);
    }

    // =============================================================================
    // AAVE OPERATIONS
    // =============================================================================

    function aaveSupply(
        bytes32 _idempotencyKey,
        address _token,
        uint256 _supplyAmount
    ) public onlyRole(SERVICE_ROLE) idempotent(OperationType.AaveSupply, _idempotencyKey) whenNotPaused {
        _assertNonZero(_token);
        _assertNonZero(_supplyAmount);
        _assertOperationLimit(OperationType.AaveSupply, _supplyAmount);

        IAaveTreasuryConnector connector = aaveTreasuryConnector;

        if (connector.isETH(_token)) {
            _assertSufficientFunds(_supplyAmount);
            connector.supply{value: _supplyAmount}(_token, _supplyAmount, aaveReferralCode);
        } else {
            IERC20(_token).safeIncreaseAllowance(address(connector), _supplyAmount);
            connector.supply(_token, _supplyAmount, aaveReferralCode);
        }

        emit AaveSupplied(_idempotencyKey, _token, _supplyAmount);
    }

    function aaveBorrow(
        bytes32 _idempotencyKey,
        address _token,
        uint256 _borrowAmount,
        uint256 _rateMode
    ) public onlyRole(SERVICE_ROLE) idempotent(OperationType.AaveBorrow, _idempotencyKey) whenNotPaused {
        _assertNonZero(_token);
        _assertNonZero(_borrowAmount);
        _assertOperationLimit(OperationType.AaveBorrow, _borrowAmount);

        IAaveTreasuryConnector connector = aaveTreasuryConnector;
        connector.borrow(_token, _borrowAmount, _rateMode, aaveReferralCode);

        emit AaveBorrowed(_idempotencyKey, _token, _borrowAmount, _rateMode);
    }

    function aaveSupplyAndBorrow(
        bytes32 _idempotencyKey,
        address _supplyToken,
        uint256 _supplyAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _rateMode
    ) external onlyRole(SERVICE_ROLE) whenNotPaused {
        aaveSupply(_idempotencyKey, _supplyToken, _supplyAmount);
        aaveBorrow(_idempotencyKey, _borrowToken, _borrowAmount, _rateMode);
    }

    /**
    * @param _repayAmount Use `type(uint256).max` to repay the maximum available amount.
    */
    function aaveRepay(
        bytes32 _idempotencyKey,
        address _token,
        uint256 _repayAmount,
        uint256 _rateMode
    ) public onlyRole(SERVICE_ROLE) idempotent(OperationType.AaveRepay, _idempotencyKey) whenNotPaused {
        _assertNonZero(_token);
        _assertNonZero(_repayAmount);
        _assertOperationLimit(OperationType.AaveRepay, _repayAmount);

        IAaveTreasuryConnector connector = aaveTreasuryConnector;

        if (connector.isETH(_token)) {
            if (_repayAmount == type(uint256).max) {
                _repayAmount = connector.getCurrentDebt(
                    connector.getWETHAddress(),
                    _rateMode
                );
            }
            _assertSufficientFunds(_repayAmount);
            connector.repay{value: _repayAmount}(_token, _repayAmount, _rateMode);
        } else {
            if (_repayAmount == type(uint256).max) {
                _repayAmount = connector.getCurrentDebt(
                    _token,
                    _rateMode
                );
            }
            IERC20(_token).safeIncreaseAllowance(address(connector), _repayAmount);
            connector.repay(_token, _repayAmount, _rateMode);
        }

        emit AaveRepaid(_idempotencyKey, _token, _repayAmount, _rateMode);
    }

    /**
    * @param _withdrawAmount Use `type(uint256).max` to withdraw the maximum available amount.
    */
    function aaveWithdraw(
        bytes32 _idempotencyKey,
        address _token,
        uint256 _withdrawAmount
    ) public onlyRole(SERVICE_ROLE) idempotent(OperationType.AaveWithdraw, _idempotencyKey) whenNotPaused {
        _assertNonZero(_token);
        _assertNonZero(_withdrawAmount);
        _assertOperationLimit(OperationType.AaveWithdraw, _withdrawAmount);

        IAaveTreasuryConnector connector = aaveTreasuryConnector;

        if (_withdrawAmount == type(uint256).max) {
            _withdrawAmount = connector.getATokenBalance(
                connector.isETH(_token)
                    ? connector.getWETHAddress()
                    : _token
            );
        }

        connector.withdraw(_token, _withdrawAmount);

        emit AaveWithdrawn(_idempotencyKey, _token, _withdrawAmount);
    }

    function setAaveTreasuryConnector(
        address _aaveTreasuryConnector
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_aaveTreasuryConnector);
        if (_aaveTreasuryConnector.code.length == 0) revert InvalidAaveTreasuryConnector(_aaveTreasuryConnector);

        aaveTreasuryConnector = IAaveTreasuryConnector(_aaveTreasuryConnector);

        emit AaveTreasuryConnectorSet(_aaveTreasuryConnector);
    }

    function aaveRepayAndWithdraw(
        bytes32 _idempotencyKey,
        address _repayToken,
        uint256 _repayAmount,
        address _withdrawToken,
        uint256 _withdrawAmount,
        uint256 _rateMode
    ) external onlyRole(SERVICE_ROLE) whenNotPaused {
        aaveRepay(_idempotencyKey, _repayToken, _repayAmount, _rateMode);
        aaveWithdraw(_idempotencyKey, _withdrawToken, _withdrawAmount);
    }

    function setAaveReferralCode(
        uint16 _aaveReferralCode
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        aaveReferralCode = _aaveReferralCode;

        emit AaveReferralCodeSet(_aaveReferralCode);
    }

    // =============================================================================
    // SILO OPERATIONS
    // =============================================================================

    function siloDeposit(
        bytes32 _idempotencyKey,
        address _asset,
        address _siloVault,
        uint256 _amount
    ) external onlyRole(SERVICE_ROLE) idempotent(OperationType.SiloDeposit, _idempotencyKey) whenNotPaused returns (uint256 shares) {
        _assertNonZero(_asset);
        _assertNonZero(_siloVault);
        _assertNonZero(_amount);
        _assertOperationLimit(OperationType.SiloDeposit, _amount);

        IERC20(_asset).safeIncreaseAllowance(address(siloTreasuryConnector), _amount);
        shares = siloTreasuryConnector.deposit(_asset, _siloVault, _amount);

        emit SiloDeposited(_idempotencyKey, _asset, _siloVault, _amount, shares);

        return shares;
    }

    function siloWithdraw(
        bytes32 _idempotencyKey,
        address _asset,
        address _siloVault,
        uint256 _amount
    ) external onlyRole(SERVICE_ROLE) idempotent(OperationType.SiloWithdraw, _idempotencyKey) whenNotPaused returns (uint256 withdrawn) {
        _assertNonZero(_asset);
        _assertNonZero(_siloVault);
        _assertNonZero(_amount);
        _assertOperationLimit(OperationType.SiloWithdraw, _amount);

        withdrawn = siloTreasuryConnector.withdraw(_asset, _siloVault, _amount);

        emit SiloWithdrawn(_idempotencyKey, _asset, _siloVault, _amount, withdrawn);

        return withdrawn;
    }

    function setSiloTreasuryConnector(
        address _siloTreasuryConnector
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_siloTreasuryConnector);
        if (_siloTreasuryConnector.code.length == 0) revert InvalidSiloTreasuryConnector(_siloTreasuryConnector);

        siloTreasuryConnector = ISiloTreasuryConnector(_siloTreasuryConnector);

        emit SiloTreasuryConnectorSet(_siloTreasuryConnector);
    }

    // =============================================================================
    // EULER OPERATIONS
    // =============================================================================

    function eulerDeposit(
        bytes32 _idempotencyKey,
        address _asset,
        address _eulerVault,
        uint256 _amount
    ) external onlyRole(SERVICE_ROLE) idempotent(OperationType.EulerDeposit, _idempotencyKey) whenNotPaused returns (uint256 shares) {
        _assertNonZero(_asset);
        _assertNonZero(_eulerVault);
        _assertNonZero(_amount);
        _assertOperationLimit(OperationType.EulerDeposit, _amount);

        IERC20(_asset).safeIncreaseAllowance(address(eulerTreasuryConnector), _amount);
        shares = eulerTreasuryConnector.deposit(_asset, _eulerVault, _amount);

        emit EulerDeposited(_idempotencyKey, _asset, _eulerVault, _amount, shares);

        return shares;
    }

    function eulerWithdraw(
        bytes32 _idempotencyKey,
        address _asset,
        address _eulerVault,
        uint256 _amount
    ) external onlyRole(SERVICE_ROLE) idempotent(OperationType.EulerWithdraw, _idempotencyKey) whenNotPaused returns (uint256 withdrawn) {
        _assertNonZero(_asset);
        _assertNonZero(_eulerVault);
        _assertNonZero(_amount);
        _assertOperationLimit(OperationType.EulerWithdraw, _amount);

        withdrawn = eulerTreasuryConnector.withdraw(_asset, _eulerVault, _amount);

        emit EulerWithdrawn(_idempotencyKey, _asset, _eulerVault, _amount, withdrawn);

        return withdrawn;
    }

    function eulerEnableCollateral(
        bytes32 _idempotencyKey,
        address _eulerVault
    ) external onlyRole(SERVICE_ROLE) idempotent(OperationType.EulerEnableCollateral, _idempotencyKey) whenNotPaused {
        _assertNonZero(_eulerVault);

        eulerTreasuryConnector.enableCollateral(_eulerVault);

        emit EulerCollateralEnabled(_idempotencyKey, _eulerVault);
    }

    function eulerDisableCollateral(
        bytes32 _idempotencyKey,
        address _eulerVault
    ) external onlyRole(SERVICE_ROLE) idempotent(OperationType.EulerDisableCollateral, _idempotencyKey) whenNotPaused {
        _assertNonZero(_eulerVault);

        eulerTreasuryConnector.disableCollateral(_eulerVault);

        emit EulerCollateralDisabled(_idempotencyKey, _eulerVault);
    }

    function setEulerTreasuryConnector(
        address _eulerTreasuryConnector
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_eulerTreasuryConnector);
        if (_eulerTreasuryConnector.code.length == 0) revert InvalidEulerTreasuryConnector(_eulerTreasuryConnector);

        eulerTreasuryConnector = IEulerTreasuryConnector(_eulerTreasuryConnector);

        emit EulerTreasuryConnectorSet(_eulerTreasuryConnector);
    }

    // =============================================================================
    // REDEMPTION CONFIGURATION
    // =============================================================================

    function setCooldownDuration(uint256 _cooldownDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        cooldownDuration = _cooldownDuration;
        emit CooldownDurationSet(_cooldownDuration);
    }

    function setMaxRedeemPerBlock(uint256 _maxRedeemPerBlock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxRedeemPerBlock = _maxRedeemPerBlock;
        emit MaxRedeemPerBlockSet(_maxRedeemPerBlock);
    }

    function setRedeemableAsset(address _asset, bool _isRedeemable) external onlyRole(DEFAULT_ADMIN_ROLE) {
        redeemableAssets[_asset] = _isRedeemable;
        emit RedeemableAssetSet(_asset, _isRedeemable);
    }

    function addSiloVault(
        address _vault,
        address _connector,
        uint256 _allocation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        siloVaults.push(VaultConfig({
            vault: _vault,
            connector: _connector,
            allocation: _allocation,
            isActive: true
        }));
        emit VaultAdded(_vault, _connector, _allocation, "Silo");
    }

    function addEulerVault(
        address _vault,
        address _connector,
        uint256 _allocation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        eulerVaults.push(VaultConfig({
            vault: _vault,
            connector: _connector,
            allocation: _allocation,
            isActive: true
        }));
        emit VaultAdded(_vault, _connector, _allocation, "Euler");
    }

    function setSiloVaultStatus(uint256 _index, bool _isActive) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_index >= siloVaults.length) revert InvalidVaultIndex();
        siloVaults[_index].isActive = _isActive;
        emit VaultStatusSet(siloVaults[_index].vault, _isActive);
    }

    function setEulerVaultStatus(uint256 _index, bool _isActive) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_index >= eulerVaults.length) revert InvalidVaultIndex();
        eulerVaults[_index].isActive = _isActive;
        emit VaultStatusSet(eulerVaults[_index].vault, _isActive);
    }

    function setChainlinkOracle(address _chainlinkOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chainlinkOracle = IChainlinkOracle(_assertNonZero(_chainlinkOracle));
        emit ChainlinkOracleSet(_chainlinkOracle);
    }

    function setEscrow(address _escrow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        escrow = IEscrow(_assertNonZero(_escrow));
        emit EscrowSet(_escrow);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    function getSiloVaultsCount() external view returns (uint256) {
        return siloVaults.length;
    }

    function getEulerVaultsCount() external view returns (uint256) {
        return eulerVaults.length;
    }

    function getSiloVault(uint256 _index) external view returns (VaultConfig memory) {
        if (_index >= siloVaults.length) revert InvalidVaultIndex();
        return siloVaults[_index];
    }

    function getEulerVault(uint256 _index) external view returns (VaultConfig memory) {
        if (_index >= eulerVaults.length) revert InvalidVaultIndex();
        return eulerVaults[_index];
    }

    function getUserRedemptionInfo(address _user) external view returns (
        uint256 pendingAmount,
        uint256 cooldownStart,
        uint256 cooldownEnd,
        bool canComplete
    ) {
        pendingAmount = pendingRedemptions[_user][USDC_ADDRESS];
        cooldownStart = userCooldowns[_user][USDC_ADDRESS];
        cooldownEnd = cooldownStart + cooldownDuration;
        canComplete = pendingAmount > 0 && block.timestamp >= cooldownEnd;
    }

    function getBlockRedemptionInfo(uint256 _blockNumber) external view returns (uint256 redeemedAmount) {
        return redeemedPerBlock[_blockNumber];
    }

    // =============================================================================
    // INTERNAL UTILITY FUNCTIONS
    // =============================================================================

    function _assertOperationLimit(OperationType _operation, uint256 _amount) internal view {
        if (_amount > operationLimits[_operation]) revert OperationLimitExceeded(_operation, _amount);
    }

    function _assertSufficientFunds(uint256 _amount) internal view {
        if (_amount > address(this).balance) revert InsufficientFunds();
    }

    function _assertNonZero(address _address) internal pure returns (address nonZeroAddress) {
        if (_address == address(0)) revert ZeroAddress();
        return _address;
    }

    function _assertNonZero(uint256 _amount) internal pure {
        if (_amount == 0) revert InvalidAmount(_amount);
    }
}