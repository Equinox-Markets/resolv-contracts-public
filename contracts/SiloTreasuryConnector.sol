// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {ISiloTreasuryConnector} from "./interfaces/ISiloTreasuryConnector.sol";

contract SiloTreasuryConnector is ISiloTreasuryConnector, AccessControlDefaultAdminRulesUpgradeable {

    using SafeERC20 for IERC20;

    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __AccessControlDefaultAdminRules_init(1 days, msg.sender);
    }

    /**
     * @dev Deposits assets into Silo finance vault
     * @param _asset The asset to deposit
     * @param _siloVault The Silo vault address (ERC4626 compliant)
     * @param _amount The amount of assets to deposit
     * @return shares The amount of shares received
     */
    function deposit(
        address _asset,
        address _siloVault,
        uint256 _amount
    ) external onlyRole(TREASURY_ROLE) returns (uint256 shares) {
        _assertNonZero(_asset);
        _assertNonZero(_siloVault);
        _assertNonZero(_amount);

        IERC4626 vault = IERC4626(_siloVault);
        
        // Verify vault asset matches
        if (vault.asset() != _asset) {
            revert InvalidSiloVault(_siloVault);
        }

        // Transfer assets from treasury to this connector
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        
        // Approve vault to spend assets
        IERC20(_asset).safeIncreaseAllowance(_siloVault, _amount);

        // Deposit into vault and receive shares
        shares = vault.deposit(_amount, msg.sender);

        if (shares == 0) {
            revert DepositFailed();
        }

        emit SiloDeposited(_asset, _siloVault, _amount, shares);

        return shares;
    }

    /**
     * @dev Withdraws assets from Silo finance vault
     * @param _asset The asset to withdraw
     * @param _siloVault The Silo vault address (ERC4626 compliant)
     * @param _amount The amount of assets to withdraw
     * @return withdrawn The amount of assets withdrawn
     */
    function withdraw(
        address _asset,
        address _siloVault,
        uint256 _amount
    ) external onlyRole(TREASURY_ROLE) returns (uint256 withdrawn) {
        _assertNonZero(_asset);
        _assertNonZero(_siloVault);
        _assertNonZero(_amount);

        IERC4626 vault = IERC4626(_siloVault);
        
        // Verify vault asset matches
        if (vault.asset() != _asset) {
            revert InvalidSiloVault(_siloVault);
        }

        // Calculate shares needed for withdrawal
        uint256 sharesToRedeem = vault.previewWithdraw(_amount);
        
        // Withdraw from vault
        withdrawn = vault.withdraw(_amount, msg.sender, msg.sender);

        if (withdrawn == 0) {
            revert WithdrawFailed();
        }

        emit SiloWithdrawn(_asset, _siloVault, withdrawn, sharesToRedeem);

        return withdrawn;
    }

    /**
     * @dev Returns the vault share balance for the treasury
     * @param _siloVault The Silo vault address
     * @return shares The share balance
     */
    function getVaultBalance(address _siloVault) external view returns (uint256 shares) {
        return IERC20(_siloVault).balanceOf(msg.sender);
    }

    /**
     * @dev Preview deposit to calculate shares
     * @param _siloVault The Silo vault address
     * @param _amount The amount to deposit
     * @return shares The expected shares
     */
    function previewDeposit(
        address _siloVault,
        uint256 _amount
    ) external view returns (uint256 shares) {
        return IERC4626(_siloVault).previewDeposit(_amount);
    }

    /**
     * @dev Preview withdraw to calculate shares needed
     * @param _siloVault The Silo vault address
     * @param _amount The amount to withdraw
     * @return shares The shares needed
     */
    function previewWithdraw(
        address _siloVault,
        uint256 _amount
    ) external view returns (uint256 shares) {
        return IERC4626(_siloVault).previewWithdraw(_amount);
    }

    function _assertNonZero(address _address) internal pure {
        if (_address == address(0)) revert ZeroAddress();
    }

    function _assertNonZero(uint256 _amount) internal pure {
        if (_amount == 0) revert InvalidAmount(_amount);
    }
}