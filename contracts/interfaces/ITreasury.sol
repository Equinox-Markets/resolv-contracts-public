// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IDefaultErrors} from "./IDefaultErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITreasury is IDefaultErrors {

    event Received(address indexed _from, uint256 _amount);
    event OperationLimitSet(OperationType _operation, uint256 _limit);
    event TransferredETH(bytes32 indexed _idempotencyKey, address indexed _to, uint256 _amount);
    event TransferredERC20(bytes32 indexed _idempotencyKey, address indexed _token, address indexed _to, uint256 _amount);
    event IncreasedAllowance(bytes32 indexed _idempotencyKey, address indexed _token, address indexed _spender, uint256 _increaseAmount);
    event DecreasedAllowance(bytes32 indexed _idempotencyKey, address indexed _token, address indexed _spender, uint256 _decreaseAmount);
    event RecipientWhitelistSet(address indexed recipientWhitelist);
    event SpenderWhitelistSet(address indexed spenderWhitelist);
    event RecipientWhitelistEnabledSet(bool isEnabled);
    event SpenderWhitelistEnabledSet(bool isEnabled);
    
    // AAVE Events
    event AaveSupplied(bytes32 indexed _idempotencyKey, address indexed _token, uint256 _amount);
    event AaveBorrowed(bytes32 indexed _idempotencyKey, address indexed _token, uint256 _amount, uint256 _rateMode);
    event AaveRepaid(bytes32 indexed _idempotencyKey, address indexed _token, uint256 _amount, uint256 _rateMode);
    event AaveWithdrawn(bytes32 indexed _idempotencyKey, address indexed _token, uint256 _amount);
    event AaveReferralCodeSet(uint16 _aaveReferralCode);
    event AaveTreasuryConnectorSet(address indexed _aaveTreasuryConnector);
    
    // SILO Events
    event SiloDeposited(bytes32 indexed _idempotencyKey, address indexed _asset, address indexed _siloVault, uint256 _amount, uint256 _shares);
    event SiloWithdrawn(bytes32 indexed _idempotencyKey, address indexed _asset, address indexed _siloVault, uint256 _amount, uint256 _withdrawn);
    event SiloTreasuryConnectorSet(address indexed _siloTreasuryConnector);
    
    // EULER Events
    event EulerDeposited(bytes32 indexed _idempotencyKey, address indexed _asset, address indexed _eulerVault, uint256 _amount, uint256 _shares);
    event EulerWithdrawn(bytes32 indexed _idempotencyKey, address indexed _asset, address indexed _eulerVault, uint256 _amount, uint256 _withdrawn);
    event EulerCollateralEnabled(bytes32 indexed _idempotencyKey, address indexed _eulerVault);
    event EulerCollateralDisabled(bytes32 indexed _idempotencyKey, address indexed _eulerVault);
    event EulerTreasuryConnectorSet(address indexed _eulerTreasuryConnector);

    // REDEMPTION Events
    event RedemptionInitiated(address indexed user, address indexed asset, uint256 assetAmount, uint256 usdxAmount);
    event RedemptionCompleted(address indexed user, address indexed beneficiary, address indexed asset, uint256 assetAmount);
    event CooldownDurationSet(uint256 duration);
    event MaxRedeemPerBlockSet(uint256 maxAmount);
    event RedeemableAssetSet(address indexed asset, bool isRedeemable);
    event VaultAdded(address indexed vault, address indexed connector, uint256 allocation, string vaultType);

    error InsufficientFunds();
    error OperationLimitExceeded(OperationType _operation, uint256 _amount);
    error UnknownRecipient(address _recipient);
    error UnknownSpender(address _spender);
    error InvalidRecipientWhitelist(address _recipientWhitelist);
    error InvalidSpenderWhitelist(address _spenderWhitelist);
    error InvalidAaveTreasuryConnector(address _aaveTreasuryConnector);
    error InvalidSiloTreasuryConnector(address _siloTreasuryConnector);
    error InvalidEulerTreasuryConnector(address _eulerTreasuryConnector);
    
    // Redemption errors
    error UnsupportedAsset();
    error MinimumCollateralAmountNotMet();
    error ExceedsMaxBlockLimit();
    error StillInCooldown();
    error NoPendingRedemptions();
    error InsufficientLiquidity();

    enum OperationType {
        AaveSupply,
        AaveBorrow,
        AaveWithdraw,
        AaveRepay,
        SiloDeposit,
        SiloWithdraw,
        EulerDeposit,
        EulerWithdraw,
        EulerEnableCollateral,
        EulerDisableCollateral,
        TransferETH,
        TransferERC20,
        IncreaseAllowance,
        DecreaseAllowance,
        InitiateRedemption
    }

    function setOperationLimit(
        OperationType _operation,
        uint256 _limit
    ) external;

    function setRecipientWhitelist(address _recipientWhitelist) external;

    function setRecipientWhitelistEnabled(bool _isEnabled) external;

    function setSpenderWhitelistEnabled(bool _isEnabled) external;

    function setSpenderWhitelist(address _spenderWhitelist) external;

    function pause() external;

    function unpause() external;

    function transferETH(
        bytes32 _idempotencyKey,
        address payable _to,
        uint256 _amount
    ) external;

    function transferERC20(
        bytes32 _idempotencyKey,
        IERC20 _token,
        address _to,
        uint256 _amount
    ) external;

    function increaseAllowance(
        bytes32 _idempotencyKey,
        IERC20 _token,
        address _spender,
        uint256 _increaseAmount
    ) external;

    function decreaseAllowance(
        bytes32 _idempotencyKey,
        IERC20 _token,
        address _spender,
        uint256 _decreaseAmount
    ) external;

    // AAVE Functions
    function aaveSupply(
        bytes32 _idempotencyKey,
        address _token,
        uint256 _supplyAmount
    ) external;

    function aaveBorrow(
        bytes32 _idempotencyKey,
        address _token,
        uint256 _borrowAmount,
        uint256 _rateMode
    ) external;

    function aaveSupplyAndBorrow(
        bytes32 _idempotencyKey,
        address _supplyToken,
        uint256 _supplyAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        uint256 _rateMode
    ) external;

    function aaveRepay(
        bytes32 _idempotencyKey,
        address _token,
        uint256 _repayAmount,
        uint256 _rateMode
    ) external;

    function aaveWithdraw(
        bytes32 _idempotencyKey,
        address _token,
        uint256 _withdrawAmount
    ) external;

    function aaveRepayAndWithdraw(
        bytes32 _idempotencyKey,
        address _repayToken,
        uint256 _repayAmount,
        address _withdrawToken,
        uint256 _withdrawAmount,
        uint256 _rateMode
    ) external;

    function setAaveTreasuryConnector(
        address _aaveTreasuryConnector
    ) external;

    function setAaveReferralCode(
        uint16 _aaveReferralCode
    ) external;

    // SILO Functions
    function siloDeposit(
        bytes32 _idempotencyKey,
        address _asset,
        address _siloVault,
        uint256 _amount
    ) external returns (uint256 shares);

    function siloWithdraw(
        bytes32 _idempotencyKey,
        address _asset,
        address _siloVault,
        uint256 _amount
    ) external returns (uint256 withdrawn);

    function setSiloTreasuryConnector(
        address _siloTreasuryConnector
    ) external;

    // EULER Functions
    function eulerDeposit(
        bytes32 _idempotencyKey,
        address _asset,
        address _eulerVault,
        uint256 _amount
    ) external returns (uint256 shares);

    function eulerWithdraw(
        bytes32 _idempotencyKey,
        address _asset,
        address _eulerVault,
        uint256 _amount
    ) external returns (uint256 withdrawn);

    function eulerEnableCollateral(
        bytes32 _idempotencyKey,
        address _eulerVault
    ) external;

    function eulerDisableCollateral(
        bytes32 _idempotencyKey,
        address _eulerVault
    ) external;

    function setEulerTreasuryConnector(
        address _eulerTreasuryConnector
    ) external;

    // REDEMPTION Functions
    function initiateRedemption(
        uint256 _usdxAmount,
        uint256 _minUsdcAmount
    ) external returns (uint256 usdxAmount, uint256 usdcAmount);

    function completeRedemption(
        address _beneficiary
    ) external returns (uint256 usdcAmount);

    function computeRedemption(
        address _asset,
        uint256 _usdxAmount
    ) external view returns (uint256 usdcAmount);

    function setCooldownDuration(uint256 _cooldownDuration) external;

    function setMaxRedeemPerBlock(uint256 _maxRedeemPerBlock) external;

    function setRedeemableAsset(address _asset, bool _isRedeemable) external;
}