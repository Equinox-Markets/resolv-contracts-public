// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IEscrow {

    event AssetWithdrawn(address indexed beneficiary, address indexed asset, uint256 amount);
    event EmergencyRecovery(address indexed asset, uint256 amount);

    function withdraw(
        address _beneficiary,
        address _asset,
        uint256 _amount
    ) external;

    function getBalance(address _asset) external view returns (uint256 balance);

    function emergencyRecover(
        address _asset,
        uint256 _amount
    ) external;
}