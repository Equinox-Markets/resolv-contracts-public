// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IStUSDX {

    event Deposit(address indexed _sender, address indexed _receiver, uint256 _usdxAmount, uint256 _shares);
    event Withdraw(address indexed _sender, address indexed _receiver, uint256 _usdxAmount, uint256 _shares);

    error InvalidDepositAmount(uint256 _usdxAmount);

    function deposit(uint256 _usdxAmount, address _receiver) external;

    function deposit(uint256 _usdxAmount) external;

    function depositWithPermit(
        uint256 _usdxAmount,
        address _receiver,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external;

    function depositWithPermit(
        uint256 _usdxAmount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external;

    function withdraw(uint256 _usdxAmount, address _receiver) external;

    function withdraw(uint256 _usdxAmount) external;

    function withdrawAll() external;

    function previewDeposit(uint256 _usdxAmount) external view returns (uint256 shares);

    function previewWithdraw(uint256 _usdxAmount) external view returns (uint256 shares);
}