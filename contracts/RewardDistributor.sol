// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISimpleToken} from "./interfaces/ISimpleToken.sol";
import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";
import {IERC20Rebasing} from "./interfaces/IERC20Rebasing.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IChainlinkOracle} from "./interfaces/oracles/IChainlinkOracle.sol";

contract RewardDistributor is IRewardDistributor, AccessControlDefaultAdminRules, Pausable {

    using Math for uint256;

    bytes32 public constant SERVICE_ROLE = keccak256("SERVICE_ROLE");
    uint256 public constant HEARTBEAT_INTERVAL = 86400; // 24 hours
    uint256 public constant PRICE_SCALE = 1e18;

    address public immutable SUSDX_ADDRESS;
    address public immutable USDX_ADDRESS;
    address public feeCollectorAddress;
    ITreasury public treasury;
    IChainlinkOracle public chainlinkOracle;

    // Vault configurations for yield calculation
    struct VaultConfig {
        address vault;          // ERC4626 vault address
        address asset;          // Underlying asset (USDC)
        uint256 allocation;     // Allocation percentage (basis points, 10000 = 100%)
        bool isActive;         // Whether vault is active for yield calculation
    }

    mapping(address => VaultConfig) public siloVaults;
    mapping(address => VaultConfig) public eulerVaults;
    address[] public activeSiloVaults;
    address[] public activeEulerVaults;

    mapping(bytes32 => bool) private distributeIds;

    modifier idempotent(bytes32 idempotencyKey) {
        if (distributeIds[idempotencyKey]) {
            revert IdempotencyKeyAlreadyExist(idempotencyKey);
        }
        _;
        distributeIds[idempotencyKey] = true;
    }

    constructor(
        address _sUSDXAddress,
        address _feeCollectorAddress,
        address _usdxAddress,
        address _treasury,
        address _chainlinkOracle
    ) AccessControlDefaultAdminRules(1 days, msg.sender) {
        SUSDX_ADDRESS = _assertNonZero(_sUSDXAddress);
        feeCollectorAddress = _assertNonZero(_feeCollectorAddress);
        USDX_ADDRESS = _assertNonZero(_usdxAddress);
        treasury = ITreasury(_assertNonZero(_treasury));
        chainlinkOracle = IChainlinkOracle(_assertNonZero(_chainlinkOracle));
    }

    /**
     * @dev Calculate and distribute yield from Silo and Euler vaults
     * @param _idempotencyKey Unique key for idempotency
     * @param _feeReward Additional fee reward to distribute
     */
    function distributeYield(
        bytes32 _idempotencyKey,
        uint256 _feeReward
    ) external onlyRole(SERVICE_ROLE) idempotent(_idempotencyKey) whenNotPaused {
        uint256 totalYield = getAccruedYield();
        
        if (totalYield == 0) {
            revert InvalidAmount(totalYield);
        }

        IERC20Rebasing sUSDX = IERC20Rebasing(SUSDX_ADDRESS);
        uint256 totalShares = sUSDX.totalShares();
        uint256 totalUSDXBefore = sUSDX.totalSupply();

        // Mint USDX for yield to sUSDX contract (increases backing ratio)
        ISimpleToken usdxToken = ISimpleToken(USDX_ADDRESS);
        usdxToken.mint(SUSDX_ADDRESS, totalYield);

        uint256 totalUSDXAfter = totalUSDXBefore + totalYield;

        // Mint additional fee rewards if any
        if (_feeReward > 0) {
            usdxToken.mint(feeCollectorAddress, _feeReward);
        }

        emit RewardDistributed(
            _idempotencyKey,
            totalShares,
            totalUSDXBefore,
            totalUSDXAfter,
            totalYield,
            _feeReward
        );
    }

    /**
     * @dev Calculate total accrued yield from all active vaults
     * @return totalYield The total yield available across all vaults
     */
    function getAccruedYield() public view returns (uint256 totalYield) {
        uint256 siloYield = _calculateVaultYield(activeSiloVaults);
        uint256 eulerYield = _calculateVaultYield(activeEulerVaults);
        
        totalYield = siloYield + eulerYield;
        
        return totalYield;
    }

    /**
     * @dev Calculate yield from a list of vaults
     * @param vaultAddresses Array of vault addresses to calculate yield from
     * @return totalYield Total yield from all vaults
     */
    function _calculateVaultYield(address[] memory vaultAddresses) internal view returns (uint256 totalYield) {
        uint256 totalDeposited = _getTotalDeposited();
        
        if (totalDeposited == 0) {
            return 0;
        }

        for (uint256 i = 0; i < vaultAddresses.length; i++) {
            address vaultAddress = vaultAddresses[i];
            VaultConfig memory config = _getVaultConfig(vaultAddress);
            
            if (!config.isActive) {
                continue;
            }

            uint256 vaultYield = _calculateSingleVaultYield(vaultAddress, config);
            totalYield += vaultYield;
        }

        return totalYield;
    }

    /**
     * @dev Calculate yield from a single vault
     * @param vaultAddress The vault address
     * @param config The vault configuration
     * @return yieldAmount Yield amount in USDC (scaled to 18 decimals)
     */
    function _calculateSingleVaultYield(
        address vaultAddress,
        VaultConfig memory config
    ) internal view returns (uint256 yieldAmount) {
        IERC4626 vault = IERC4626(vaultAddress);
        IERC20 asset = IERC20(config.asset);
        
        // Get treasury's share balance in the vault
        uint256 shares = vault.balanceOf(address(treasury));
        if (shares == 0) {
            return 0;
        }

        // Convert shares to assets to get current vault value
        uint256 currentAssets = vault.convertToAssets(shares);
        
        // Get the initial deposit amount (this should be tracked separately in production)
        // For now, we'll calculate based on allocation percentage
        uint256 totalDeposited = _getTotalDeposited();
        uint256 expectedDeposit = totalDeposited.mulDiv(config.allocation, 10000);
        
        // Apply price adjustment if asset is under peg
        uint256 adjustedAssets = _applyPriceAdjustment(config.asset, currentAssets);
        
        // Yield is the difference between current value and initial deposit
        if (adjustedAssets > expectedDeposit) {
            yieldAmount = adjustedAssets - expectedDeposit;
        } else {
            yieldAmount = 0;
        }

        return yieldAmount;
    }

    /**
     * @dev Apply price adjustment for assets under peg
     * @param asset The asset address
     * @param amount The amount to adjust
     * @return adjustedAmount The price-adjusted amount
     */
    function _applyPriceAdjustment(address asset, uint256 amount) internal view returns (uint256 adjustedAmount) {
        try chainlinkOracle.getLatestRoundData(asset) returns (
            uint80, int256 price, uint256, uint256 updatedAt, uint80
        ) {
            // Check if price data is recent
            if (block.timestamp - updatedAt > HEARTBEAT_INTERVAL) {
                return amount; // Use original amount if stale
            }

            uint8 priceDecimals = chainlinkOracle.priceDecimals(asset);
            uint256 priceScale = 10 ** priceDecimals;
            
            // If price is under peg (less than 1.0), adjust amount down
            if (uint256(price) < priceScale) {
                adjustedAmount = amount.mulDiv(uint256(price), priceScale);
            } else {
                adjustedAmount = amount;
            }
        } catch {
            // If oracle fails, use original amount
            adjustedAmount = amount;
        }

        return adjustedAmount;
    }

    /**
     * @dev Get total USDX deposited (excluding yield)
     * @return totalDeposited Total deposited amount
     */
    function _getTotalDeposited() internal view returns (uint256 totalDeposited) {
        IERC20Rebasing sUSDX = IERC20Rebasing(SUSDX_ADDRESS);
        uint256 totalShares = sUSDX.totalShares();
        
        // Add offset to prevent division by zero and match the rebasing contract logic
        totalDeposited = totalShares + 1000;
        
        return totalDeposited;
    }

    /**
     * @dev Get vault configuration for a given vault address
     * @param vaultAddress The vault address
     * @return config The vault configuration
     */
    function _getVaultConfig(address vaultAddress) internal view returns (VaultConfig memory config) {
        config = siloVaults[vaultAddress];
        if (config.vault == address(0)) {
            config = eulerVaults[vaultAddress];
        }
        return config;
    }

    /**
     * @dev Add Silo vault configuration
     * @param _vault The vault address
     * @param _asset The underlying asset
     * @param _allocation Allocation percentage in basis points
     */
    function addSiloVault(
        address _vault,
        address _asset,
        uint256 _allocation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_vault);
        _assertNonZero(_asset);
        
        siloVaults[_vault] = VaultConfig({
            vault: _vault,
            asset: _asset,
            allocation: _allocation,
            isActive: true
        });
        
        activeSiloVaults.push(_vault);
        
        emit VaultAdded(_vault, _asset, _allocation, "Silo");
    }

    /**
     * @dev Add Euler vault configuration
     * @param _vault The vault address
     * @param _asset The underlying asset
     * @param _allocation Allocation percentage in basis points
     */
    function addEulerVault(
        address _vault,
        address _asset,
        uint256 _allocation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_vault);
        _assertNonZero(_asset);
        
        eulerVaults[_vault] = VaultConfig({
            vault: _vault,
            asset: _asset,
            allocation: _allocation,
            isActive: true
        });
        
        activeEulerVaults.push(_vault);
        
        emit VaultAdded(_vault, _asset, _allocation, "Euler");
    }

    /**
     * @dev Remove vault from active list
     * @param _vault The vault address to remove
     */
    function removeVault(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assertNonZero(_vault);
        
        // Mark as inactive
        if (siloVaults[_vault].vault != address(0)) {
            siloVaults[_vault].isActive = false;
            _removeFromArray(activeSiloVaults, _vault);
        } else if (eulerVaults[_vault].vault != address(0)) {
            eulerVaults[_vault].isActive = false;
            _removeFromArray(activeEulerVaults, _vault);
        }
        
        emit VaultRemoved(_vault);
    }

    /**
     * @dev Remove address from array
     * @param array The array to modify
     * @param item The item to remove
     */
    function _removeFromArray(address[] storage array, address item) internal {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == item) {
                array[i] = array[array.length - 1];
                array.pop();
                break;
            }
        }
    }

    function setFeeCollector(address _feeCollectorAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeCollectorAddress = _assertNonZero(_feeCollectorAddress);
        emit FeeCollectorSet(_feeCollectorAddress);
    }

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        treasury = ITreasury(_assertNonZero(_treasury));
        emit TreasurySet(_treasury);
    }

    function setChainlinkOracle(address _chainlinkOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chainlinkOracle = IChainlinkOracle(_assertNonZero(_chainlinkOracle));
        emit ChainlinkOracleSet(_chainlinkOracle);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        Pausable._pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        Pausable._unpause();
    }

    function _assertNonZero(address _address) internal pure returns (address nonZeroAddress) {
        if (_address == address(0)) revert ZeroAddress();
        return _address;
    }

    // Events
    event VaultAdded(address indexed vault, address indexed asset, uint256 allocation, string vaultType);
    event VaultRemoved(address indexed vault);
    event TreasurySet(address indexed treasury);
    event ChainlinkOracleSet(address indexed chainlinkOracle);
}