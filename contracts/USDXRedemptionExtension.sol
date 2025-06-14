import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IChainlinkOracle} from "./interfaces/oracles/IChainlinkOracle.sol";
import {ISiloTreasuryConnector} from "./interfaces/ISiloTreasuryConnector.sol";
import {IEulerTreasuryConnector} from "./interfaces/IEulerTreasuryConnector.sol";
import {IAaveTreasuryConnector} from "./interfaces/IAaveTreasuryConnector.sol";

contract USDXRedemptionExtension is IUSDXRedemptionExtension, AccessControlDefaultAdminRules, Pausable {
    
    using Math for uint256;
    
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    
    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant USDX_DECIMALS = 18;
    uint256 public constant PRICE_SCALE = 1e18;
    uint256 public constant HEARTBEAT_INTERVAL = 86400; // 24 hours
    
    address public immutable USDX_ADDRESS;
    address public immutable USDC_ADDRESS;
    
    IChainlinkOracle public chainlinkOracle;
    ISiloTreasuryConnector public siloTreasuryConnector;
    IEulerTreasuryConnector public eulerTreasuryConnector;
    IAaveTreasuryConnector public aaveTreasuryConnector;
    
    // Redemption parameters
    uint256 public maxRedemptionPerBlock;
    mapping(address asset => bool isRedeemable) public redeemableAssets;
    mapping(uint256 blockNumber => uint256 amount) public redeemedPerBlock;
    
    // Vault configurations for withdrawal planning
    VaultInfo[] public siloVaults;
    VaultInfo[] public eulerVaults;
    VaultInfo public aaveVault;
    
    constructor(
        address _usdxAddress,
        address _usdcAddress,
        address _chainlinkOracle,
        uint256 _maxRedemptionPerBlock
    ) AccessControlDefaultAdminRules(1 days, msg.sender) {
        USDX_ADDRESS = _assertNonZero(_usdxAddress);
        USDC_ADDRESS = _assertNonZero(_usdcAddress);
        chainlinkOracle = IChainlinkOracle(_assertNonZero(_chainlinkOracle));
        maxRedemptionPerBlock = _maxRedemptionPerBlock;
        
        // USDC is redeemable by default
        redeemableAssets[USDC_ADDRESS] = true;
    }
    
    /**
     * @dev Computes asset amount for USDX redemption with price adjustment
     * @param _asset The asset to redeem (USDC)
     * @param _usdxAmount Amount of USDX to redeem
     * @return assetAmount Amount of asset to receive
     * @return priceAdjustment Price adjustment factor applied (1e18 = no adjustment)
     */
    function computeRedemption(
        address _asset,
        uint256 _usdxAmount
    ) public view returns (uint256 assetAmount, uint256 priceAdjustment) {
        if (!redeemableAssets[_asset]) revert UnsupportedAsset(_asset);
        if (_usdxAmount == 0) revert InvalidRedemptionAmount(_usdxAmount);
        
        if (_asset != USDC_ADDRESS) revert UnsupportedAsset(_asset);
        
        try chainlinkOracle.getLatestRoundData(USDC_ADDRESS) returns (
            uint80, int256 price, uint256, uint256 updatedAt, uint80
        ) {
            // Check if price data is recent
            if (block.timestamp - updatedAt > HEARTBEAT_INTERVAL) {
                // Use 1:1 conversion if stale data
                return (_convertUsdxToUsdc(_usdxAmount), PRICE_SCALE);
            }
            
            uint8 priceDecimals = chainlinkOracle.priceDecimals(USDC_ADDRESS);
            uint256 priceScale = 10 ** priceDecimals;
            
            // If USDC is trading above $1, give less USDC to maintain collateralization
            if (uint256(price) > priceScale) {
                priceAdjustment = priceScale.mulDiv(PRICE_SCALE, uint256(price));
                uint256 adjustedUsdxAmount = _usdxAmount.mulDiv(priceScale, uint256(price));
                assetAmount = _convertUsdxToUsdc(adjustedUsdxAmount);
            } else {
                // 1:1 conversion (1 USDX = 1 USDC)
                priceAdjustment = PRICE_SCALE;
                assetAmount = _convertUsdxToUsdc(_usdxAmount);
            }
        } catch {
            // Fallback to 1:1 conversion if oracle fails
            priceAdjustment = PRICE_SCALE;
            assetAmount = _convertUsdxToUsdc(_usdxAmount);
        }
        
        emit RedemptionCalculated(msg.sender, _asset, _usdxAmount, assetAmount, priceAdjustment);
    }
    
    /**
     * @dev Validates a redemption request against all constraints
     * @param _user The user requesting redemption
     * @param _asset The asset to redeem
     * @param _usdxAmount Amount of USDX to redeem
     * @param _minAssetAmount Minimum asset amount expected
     * @param _blockNumber Block number for the redemption
     * @return isValid Whether the redemption is valid
     * @return reason Reason for validation failure (if any)
     */
    function validateRedemption(
        address _user,
        address _asset,
        uint256 _usdxAmount,
        uint256 _minAssetAmount,
        uint256 _blockNumber
    ) external view returns (bool isValid, string memory reason) {
        // Check if asset is redeemable
        if (!redeemableAssets[_asset]) {
            return (false, "Asset not redeemable");
        }
        
        // Check redemption amount
        if (_usdxAmount == 0) {
            return (false, "Invalid redemption amount");
        }
        
        // Check block limits
        uint256 blockRedemptions = redeemedPerBlock[_blockNumber];
        if (blockRedemptions + _usdxAmount > maxRedemptionPerBlock) {
            return (false, "Exceeds block redemption limit");
        }
        
        // Check minimum amount constraint
        (uint256 assetAmount,) = computeRedemption(_asset, _usdxAmount);
        if (assetAmount < _minAssetAmount) {
            return (false, "Below minimum expected amount");
        }
        
        // Check liquidity availability
        (, uint256 totalAvailable) = calculateWithdrawalPlan(assetAmount);
        if (totalAvailable < assetAmount) {
            return (false, "Insufficient liquidity");
        }
        
        return (true, "");
    }
    
    /**
     * @dev Calculates optimal withdrawal plan for required amount
     * @param _requiredAmount Amount of USDC needed
     * @return withdrawalPlan Array of vaults to withdraw from
     * @return totalAvailable Total amount available across all vaults
     */
    function calculateWithdrawalPlan(
        uint256 _requiredAmount
    ) public view returns (VaultInfo[] memory withdrawalPlan, uint256 totalAvailable) {
        uint256 maxVaults = siloVaults.length + eulerVaults.length + 1; // +1 for Aave
        withdrawalPlan = new VaultInfo[](maxVaults);
        uint256 planIndex = 0;
        uint256 remaining = _requiredAmount;
        
        // First, try Silo vaults (highest allocation priority)
        for (uint256 i = 0; i < siloVaults.length && remaining > 0; i++) {
            if (!siloVaults[i].isActive) continue;
            
            uint256 vaultBalance = siloTreasuryConnector.getVaultBalance(siloVaults[i].vault);
            if (vaultBalance == 0) continue;
            
            uint256 maxWithdraw = siloTreasuryConnector.previewWithdraw(siloVaults[i].vault, remaining);
            
            if (maxWithdraw > 0) {
                uint256 toWithdraw = remaining > maxWithdraw ? maxWithdraw : remaining;
                withdrawalPlan[planIndex] = siloVaults[i];
                totalAvailable += toWithdraw;
                remaining -= toWithdraw;
                planIndex++;
            }
        }
        
        // Then, try Euler vaults
        for (uint256 i = 0; i < eulerVaults.length && remaining > 0; i++) {
            if (!eulerVaults[i].isActive) continue;
            
            uint256 vaultBalance = eulerTreasuryConnector.getVaultBalance(eulerVaults[i].vault);
            if (vaultBalance == 0) continue;
            
            uint256 maxWithdraw = eulerTreasuryConnector.previewWithdraw(eulerVaults[i].vault, remaining);
            
            if (maxWithdraw > 0) {
                uint256 toWithdraw = remaining > maxWithdraw ? maxWithdraw : remaining;
                withdrawalPlan[planIndex] = eulerVaults[i];
                totalAvailable += toWithdraw;
                remaining -= toWithdraw;
                planIndex++;
            }
        }
        
        // Finally, try Aave if still need more
        if (remaining > 0 && aaveVault.isActive) {
            uint256 aaveBalance = aaveTreasuryConnector.getATokenBalance(USDC_ADDRESS);
            if (aaveBalance > 0) {
                uint256 toWithdraw = remaining > aaveBalance ? aaveBalance : remaining;
                withdrawalPlan[planIndex] = aaveVault;
                totalAvailable += toWithdraw;
                planIndex++;
            }
        }
        
        // Resize array to actual used length
        VaultInfo[] memory finalPlan = new VaultInfo[](planIndex);
        for (uint256 i = 0; i < planIndex; i++) {
            finalPlan[i] = withdrawalPlan[i];
        }
        
        return (finalPlan, totalAvailable);
    }
    
    /**
     * @dev Gets comprehensive redemption quote with price information
     * @param _asset The asset to redeem
     * @param _usdxAmount Amount of USDX to redeem
     * @return assetAmount Amount of asset to receive
     * @return priceAdjustment Price adjustment factor
     * @return isPriceAdjusted Whether price adjustment was applied
     * @return priceSource Source of price data
     */
    function getRedemptionQuote(
        address _asset,
        uint256 _usdxAmount
    ) external view returns (
        uint256 assetAmount,
        uint256 priceAdjustment,
        bool isPriceAdjusted,
        string memory priceSource
    ) {
        (assetAmount, priceAdjustment) = computeRedemption(_asset, _usdxAmount);
        isPriceAdjusted = priceAdjustment != PRICE_SCALE;
        
        try chainlinkOracle.getLatestRoundData(_asset) returns (
            uint80, int256, uint256, uint256 updatedAt, uint80
        ) {
            if (block.timestamp - updatedAt > HEARTBEAT_INTERVAL) {
                priceSource = "Fallback (1:1)";
            } else {
                priceSource = "Chainlink Oracle";
            }
        } catch {
            priceSource = "Fallback (1:1)";
        }
    }
    
    // =============================================================================
    // CONFIGURATION FUNCTIONS
    // =============================================================================
    
    function setChainlinkOracle(address _chainlinkOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chainlinkOracle = IChainlinkOracle(_assertNonZero(_chainlinkOracle));
        emit ChainlinkOracleSet(_chainlinkOracle);
    }
    
    function setMaxRedemptionPerBlock(uint256 _maxRedemptionPerBlock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxRedemptionPerBlock = _maxRedemptionPerBlock;
        emit MaxRedemptionPerBlockSet(_maxRedemptionPerBlock);
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
        siloVaults.push(VaultInfo({
            vault: _vault,
            connector: _connector,
            allocation: _allocation,
            isActive: true,
            protocol: "Silo"
        }));
        emit VaultConfigurationUpdated(_vault, _allocation, true);
    }
    
    function addEulerVault(
        address _vault,
        address _connector,
        uint256 _allocation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        eulerVaults.push(VaultInfo({
            vault: _vault,
            connector: _connector,
            allocation: _allocation,
            isActive: true,
            protocol: "Euler"
        }));
        emit VaultConfigurationUpdated(_vault, _allocation, true);
    }
    
    function setAaveVault(
        address _vault,
        address _connector,
        uint256 _allocation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        aaveVault = VaultInfo({
            vault: _vault,
            connector: _connector,
            allocation: _allocation,
            isActive: true,
            protocol: "Aave"
        });
        emit VaultConfigurationUpdated(_vault, _allocation, true);
    }
    
    function setSiloConnector(address _connector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        siloTreasuryConnector = ISiloTreasuryConnector(_assertNonZero(_connector));
    }
    
    function setEulerConnector(address _connector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        eulerTreasuryConnector = IEulerTreasuryConnector(_assertNonZero(_connector));
    }
    
    function setAaveConnector(address _connector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        aaveTreasuryConnector = IAaveTreasuryConnector(_assertNonZero(_connector));
    }
    
    function updateBlockRedemptions(uint256 _blockNumber, uint256 _amount) external onlyRole(TREASURY_ROLE) {
        redeemedPerBlock[_blockNumber] += _amount;
    }
    
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
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
    
    function getSiloVault(uint256 _index) external view returns (VaultInfo memory) {
        require(_index < siloVaults.length, "Invalid index");
        return siloVaults[_index];
    }
    
    function getEulerVault(uint256 _index) external view returns (VaultInfo memory) {
        require(_index < eulerVaults.length, "Invalid index");
        return eulerVaults[_index];
    }
    
    function getAaveVault() external view returns (VaultInfo memory) {
        return aaveVault;
    }
    
    function getBlockRedemptions(uint256 _blockNumber) external view returns (uint256) {
        return redeemedPerBlock[_blockNumber];
    }
    
    // =============================================================================
    // INTERNAL UTILITY FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Converts USDX amount to USDC amount accounting for decimals
     * @param _usdxAmount Amount in USDX (18 decimals)
     * @return usdcAmount Amount in USDC (6 decimals)
     */
    function _convertUsdxToUsdc(uint256 _usdxAmount) internal pure returns (uint256 usdcAmount) {
        return _usdxAmount / (10 ** (USDX_DECIMALS - USDC_DECIMALS));
    }
    
    function _assertNonZero(address _address) internal pure returns (address) {
        require(_address != address(0), "Zero address");
        return _address;
    }
}