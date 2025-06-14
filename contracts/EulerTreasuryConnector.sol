// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {IEulerTreasuryConnector} from "./interfaces/IEulerTreasuryConnector.sol";

contract EulerTreasuryConnector is IEulerTreasuryConnector, AccessControlDefaultAdminRulesUpgradeable {

    using SafeERC20 for IERC20;

    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // Euler V2 EVC (Ethereum Vault Connector) address - mainnet
    address public constant EVC_ADDRESS = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __AccessControlDefaultAdminRules_init(1 days, msg.sender);
    }

    /**
     * @dev Deposits assets into Euler finance vault
     * @param _asset The asset to deposit
     * @param _eulerVault The Euler vault address (ERC4626 compliant)
     * @param _amount The amount of assets to deposit
     * @return shares The amount of shares received
     */
    function deposit(
        address _asset,
        address _eulerVault,
        uint256 _amount
    ) external onlyRole(TREASURY_ROLE) returns (uint256 shares) {
        _assertNonZero(_asset);
        _assertNonZero(_eulerVault);
        _assertNonZero(_amount);

        IERC4626 vault = IERC4626(_eulerVault);
        
        // Verify vault asset matches
        if (vault.asset() != _asset) {
            revert InvalidEulerVault(_eulerVault);
        }

        // Transfer assets from treasury to this connector
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        
        // Approve vault to spend assets
        IERC20(_asset).safeIncreaseAllowance(_eulerVault, _amount);

        // Deposit into vault and receive shares
        shares = vault.deposit(_amount, msg.sender);

        if (shares == 0) {
            revert DepositFailed();
        }

        emit EulerDeposited(_asset, _eulerVault, _amount, shares);

        return shares;
    }

    /**
     * @dev Withdraws assets from Euler finance vault
     * @param _asset The asset to withdraw
     * @param _eulerVault The Euler vault address (ERC4626 compliant)
     * @param _amount The amount of assets to withdraw
     * @return withdrawn The amount of assets withdrawn
     */
    function withdraw(
        address _asset,
        address _eulerVault,
        uint256 _amount
    ) external onlyRole(TREASURY_ROLE) returns (uint256 withdrawn) {
        _assertNonZero(_asset);
        _assertNonZero(_eulerVault);
        _assertNonZero(_amount);

        IERC4626 vault = IERC4626(_eulerVault);
        
        // Verify vault asset matches
        if (vault.asset() != _asset) {
            revert InvalidEulerVault(_eulerVault);
        }

        // Calculate shares needed for withdrawal
        uint256 sharesToRedeem = vault.previewWithdraw(_amount);
        
        // Withdraw from vault
        withdrawn = vault.withdraw(_amount, msg.sender, msg.sender);

        if (withdrawn == 0) {
            revert WithdrawFailed();
        }

        emit EulerWithdrawn(_asset, _eulerVault, withdrawn, sharesToRedeem);

        return withdrawn;
    }

    /**
     * @dev Enables collateral for the vault in EVC
     * @param _eulerVault The Euler vault address
     */
    function enableCollateral(address _eulerVault) external onlyRole(TREASURY_ROLE) {
        _assertNonZero(_eulerVault);

        // Call EVC to enable collateral
        (bool success, ) = EVC_ADDRESS.call(
            abi.encodeWithSignature("enableCollateral(address,address)", msg.sender, _eulerVault)
        );

        if (!success) {
            revert CollateralOperationFailed();
        }

        emit EulerCollateralEnabled(_eulerVault);
    }

    /**
     * @dev Disables collateral for the vault in EVC
     * @param _eulerVault The Euler vault address
     */
    function disableCollateral(address _eulerVault) external onlyRole(TREASURY_ROLE) {
        _assertNonZero(_eulerVault);

        // Call EVC to disable collateral
        (bool success, ) = EVC_ADDRESS.call(
            abi.encodeWithSignature("disableCollateral(address,address)", msg.sender, _eulerVault)
        );

        if (!success) {
            revert CollateralOperationFailed();
        }

        emit EulerCollateralDisabled(_eulerVault);
    }

    /**
     * @dev Returns the vault share balance for the treasury
     * @param _eulerVault The Euler vault address
     * @return shares The share balance
     */
    function getVaultBalance(address _eulerVault) external view returns (uint256 shares) {
        return IERC20(_eulerVault).balanceOf(msg.sender);
    }

    /**
     * @dev Preview deposit to calculate shares
     * @param _eulerVault The Euler vault address
     * @param _amount The amount to deposit
     * @return shares The expected shares
     */
    function previewDeposit(
        address _eulerVault,
        uint256 _amount
    ) external view returns (uint256 shares) {
        return IERC4626(_eulerVault).previewDeposit(_amount);
    }

    /**
     * @dev Preview withdraw to calculate shares needed
     * @param _eulerVault The Euler vault address
     * @param _amount The amount to withdraw
     * @return shares The shares needed
     */
    function previewWithdraw(
        address _eulerVault,
        uint256 _amount
    ) external view returns (uint256 shares) {
        return IERC4626(_eulerVault).previewWithdraw(_amount);
    }

    function _assertNonZero(address _address) internal pure {
        if (_address == address(0)) revert ZeroAddress();
    }

    function _assertNonZero(uint256 _amount) internal pure {
        if (_amount == 0) revert InvalidAmount(_amount);
    }
}