// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";

/**
 * @title Escrow
 * @notice Contract for securely holding assets during USDX redemption cooldown periods
 * @dev Only the Treasury contract can withdraw assets from escrow
 */
contract Escrow is IEscrow {
    using SafeERC20 for IERC20;

    address public immutable treasury;

    error Unauthorized();
    error InvalidToken();
    error ZeroAddress();
    error InvalidAmount();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert Unauthorized();
        _;
    }

    constructor(address _treasury) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    /**
     * @dev Withdraws assets from escrow to beneficiary
     * @param _beneficiary Address to receive the assets
     * @param _asset Token address to withdraw
     * @param _amount Amount to withdraw
     */
    function withdraw(
        address _beneficiary,
        address _asset,
        uint256 _amount
    ) external onlyTreasury {
        if (_beneficiary == address(0)) revert ZeroAddress();
        if (_asset == address(0)) revert InvalidToken();
        if (_amount == 0) revert InvalidAmount();
        
        // Verify token contract exists
        if (_asset.code.length == 0) revert InvalidToken();
        
        IERC20(_asset).safeTransfer(_beneficiary, _amount);
        
        emit AssetWithdrawn(_beneficiary, _asset, _amount);
    }

    /**
     * @dev Returns the balance of a specific asset held in escrow
     * @param _asset Token address to check
     * @return balance The current balance
     */
    function getBalance(address _asset) external view returns (uint256 balance) {
        return IERC20(_asset).balanceOf(address(this));
    }

    /**
     * @dev Emergency function to recover accidentally sent tokens
     * @param _asset Token address to recover
     * @param _amount Amount to recover
     * @dev Only treasury can call this function
     */
    function emergencyRecover(
        address _asset,
        uint256 _amount
    ) external onlyTreasury {
        if (_asset == address(0)) revert InvalidToken();
        if (_amount == 0) revert InvalidAmount();
        
        IERC20(_asset).safeTransfer(treasury, _amount);
        
        emit EmergencyRecovery(_asset, _amount);
    }
}