// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IDefaultErrors} from "./IDefaultErrors.sol";

interface IEulerTreasuryConnector is IDefaultErrors {

    event EulerDeposited(address indexed _asset, address indexed _eulerVault, uint256 _amount, uint256 _shares);
    event EulerWithdrawn(address indexed _asset, address indexed _eulerVault, uint256 _amount, uint256 _shares);
    event EulerCollateralEnabled(address indexed _eulerVault);
    event EulerCollateralDisabled(address indexed _eulerVault);

    error InvalidEulerVault(address _eulerVault);
    error DepositFailed();
    error WithdrawFailed();
    error CollateralOperationFailed();

    function deposit(
        address _asset,
        address _eulerVault,
        uint256 _amount
    ) external returns (uint256 shares);

    function withdraw(
        address _asset,
        address _eulerVault,
        uint256 _amount
    ) external returns (uint256 withdrawn);

    function enableCollateral(address _eulerVault) external;

    function disableCollateral(address _eulerVault) external;

    function getVaultBalance(address _eulerVault) external view returns (uint256 shares);

    function previewDeposit(
        address _eulerVault,
        uint256 _amount
    ) external view returns (uint256 shares);

    function previewWithdraw(
        address _eulerVault,
        uint256 _amount
    ) external view returns (uint256 shares);
}