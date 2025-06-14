// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IWsUSDX is IERC4626 {

    event Wrap(address indexed _sender, address indexed _receiver, uint256 _sUSDXAmount, uint256 _wsUSDXAmount);
    event Unwrap(address indexed _sender, address indexed _receiver, uint256 _sUSDXAmount, uint256 _wsUSDXAmount);

    error ExceededMaxWithdraw(address _owner, uint256 _usdxAmount, uint256 _maxUsdxAmount);
    error ExceededMaxRedeem(address _owner, uint256 _wsUSDXAmount, uint256 _maxWsUSDXAmount);

    function deposit(uint256 _usdxAmount) external returns (uint256 wsUSDXAmount);

    function depositWithPermit(
        uint256 _usdxAmount,
        address _receiver,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (uint256 wsUSDXAmount);

    function mint(uint256 _wsUSDXAmount) external returns (uint256 usdxAmount);

    function mintWithPermit(
        uint256 _wsUSDXAmount,
        address _receiver,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (uint256 usdxAmount);

    function withdraw(uint256 _usdxAmount) external returns (uint256 wsUSDXAmount);

    function redeem(uint256 _wsUSDXAmount) external returns (uint256 usdxAmount);

    function wrap(uint256 _sUSDXAmount, address _receiver) external returns (uint256 wsUSDXAmount);

    function wrap(uint256 _sUSDXAmount) external returns (uint256 wsUSDXAmount);

    function wrapWithPermit(
        uint256 _sUSDXAmount,
        address _receiver,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (uint256 wsUSDXAmount);

    function unwrap(uint256 _wsUSDXAmount, address _receiver) external returns (uint256 sUSDXAmount);

    function unwrap(uint256 _wsUSDXAmount) external returns (uint256 sUSDXAmount);
}