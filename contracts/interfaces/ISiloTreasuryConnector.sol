// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IDefaultErrors} from "./IDefaultErrors.sol";

interface ISiloTreasuryConnector is IDefaultErrors {

    event SiloDeposited(address indexed _asset, address indexed _siloVault, uint256 _amount, uint256 _shares);
    event SiloWithdrawn(address indexed _asset, address indexed _siloVault, uint256 _amount, uint256 _shares);

    error InvalidSiloVault(address _siloVault);
    error DepositFailed();
    error WithdrawFailed();

    function deposit(
        address _asset,
        address _siloVault,
        uint256 _amount
    ) external returns (uint256 shares);

    function withdraw(
        address _asset,
        address _siloVault,
        uint256 _amount
    ) external returns (uint256 withdrawn);

    function getVaultBalance(address _siloVault) external view returns (uint256 shares);

    function previewDeposit(
        address _siloVault,
        uint256 _amount
    ) external view returns (uint256 shares);

    function previewWithdraw(
        address _siloVault,
        uint256 _amount
    ) external view returns (uint256 shares);
}