// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IStUSDX} from "./interfaces/IStUSDX.sol";
import {IDefaultErrors} from "./interfaces/IDefaultErrors.sol";
import {IERC20Rebasing} from "./interfaces/IERC20Rebasing.sol";
import {IWsUSDX} from "./interfaces/IWsUSDX.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

contract WsUSDX is IWsUSDX, ERC20PermitUpgradeable, IDefaultErrors {

    using Math for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant SUSDX_SHARES_OFFSET = 1000;

    address public sUSDXAddress;
    address public usdxAddress;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _name,
        string memory _symbol,
        address _sUSDXAddress
    ) public initializer {
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);

        _assertNonZero(_sUSDXAddress);
        sUSDXAddress = _sUSDXAddress;

        usdxAddress = address(IERC20Rebasing(_sUSDXAddress).underlyingToken());
        _assertNonZero(usdxAddress);
        IERC20(usdxAddress).safeIncreaseAllowance(sUSDXAddress, type(uint256).max);
    }

    function asset() external view returns (address usdxTokenAddress) {
        return usdxAddress;
    }

    function totalAssets() external view returns (uint256 totalManagedUsdxAmount) {
        return IERC20Rebasing(sUSDXAddress).convertToUnderlyingToken(totalSupply() * SUSDX_SHARES_OFFSET);
    }

    function convertToShares(uint256 _usdxAmount) public view returns (uint256 wsUSDXAmount) {
        return IERC20Rebasing(sUSDXAddress).convertToShares(_usdxAmount) / SUSDX_SHARES_OFFSET;
    }

    function convertToAssets(uint256 _wsUSDXAmount) public view returns (uint256 usdxAmount) {
        return IERC20Rebasing(sUSDXAddress).convertToUnderlyingToken(_wsUSDXAmount * SUSDX_SHARES_OFFSET);
    }

    function maxDeposit(address) external pure returns (uint256 maxUsdxAmount) {
        return type(uint256).max;
    }

    function maxMint(address) external pure returns (uint256 maxWsUSDXAmount) {
        return type(uint256).max;
    }

    function maxWithdraw(address _owner) public view returns (uint256 maxUsdxAmount) {
        return convertToAssets(balanceOf(_owner));
    }

    function maxRedeem(address owner) public view returns (uint256 maxWsUSDXAmount) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 _usdxAmount) public view returns (uint256 wsUSDXAmount) {
        return IStUSDX(sUSDXAddress).previewDeposit(_usdxAmount) / SUSDX_SHARES_OFFSET;
    }

    function previewMint(uint256 _wsUSDXAmount) public view returns (uint256 usdxAmount) {
        IERC20Rebasing sUSDX = IERC20Rebasing(sUSDXAddress);

        return (_wsUSDXAmount * SUSDX_SHARES_OFFSET).mulDiv(
            sUSDX.totalSupply() + 1,
            sUSDX.totalShares() + SUSDX_SHARES_OFFSET,
            Math.Rounding.Ceil
        );
    }

    function previewWithdraw(uint256 _usdxAmount) public view returns (uint256 wsUSDXAmount) {
        return IStUSDX(sUSDXAddress).previewWithdraw(_usdxAmount).ceilDiv(SUSDX_SHARES_OFFSET);
    }

    function previewRedeem(uint256 _wsUSDXAmount) public view returns (uint256 usdxAmount) {
        IERC20Rebasing sUSDX = IERC20Rebasing(sUSDXAddress);

        return (_wsUSDXAmount * SUSDX_SHARES_OFFSET).mulDiv(
            sUSDX.totalSupply() + 1,
            sUSDX.totalShares() + SUSDX_SHARES_OFFSET,
            Math.Rounding.Floor
        );
    }

    function deposit(uint256 _usdxAmount, address _receiver) public returns (uint256 wsUSDXAmount) {
        wsUSDXAmount = previewDeposit(_usdxAmount);
        _deposit(msg.sender, _receiver, _usdxAmount, wsUSDXAmount);

        return wsUSDXAmount;
    }

    function deposit(uint256 _usdxAmount) external returns (uint256 wsUSDXAmount) {
        return deposit(_usdxAmount, msg.sender);
    }

    function depositWithPermit(
        uint256 _usdxAmount,
        address _receiver,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (uint256 wsUSDXAmount) {
        IERC20Permit usdxPermit = IERC20Permit(usdxAddress);
        // the use of `try/catch` allows the permit to fail and makes the code tolerant to frontrunning.
        // solhint-disable-next-line no-empty-blocks
        try usdxPermit.permit(msg.sender, address(this), _usdxAmount, _deadline, _v, _r, _s) {} catch {}
        return deposit(_usdxAmount, _receiver);
    }

    function mint(uint256 _wsUSDXAmount, address _receiver) public returns (uint256 usdxAmount) {
        usdxAmount = previewMint(_wsUSDXAmount);
        _deposit(msg.sender, _receiver, usdxAmount, _wsUSDXAmount);

        return usdxAmount;
    }

    function mint(uint256 _wsUSDXAmount) external returns (uint256 usdxAmount) {
        return mint(_wsUSDXAmount, msg.sender);
    }

    function mintWithPermit(
        uint256 _wsUSDXAmount,
        address _receiver,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (uint256 usdxAmount) {
        IERC20Permit usdxPermit = IERC20Permit(usdxAddress);
        usdxAmount = previewMint(_wsUSDXAmount);
        // the use of `try/catch` allows the permit to fail and makes the code tolerant to frontrunning.
        // solhint-disable-next-line no-empty-blocks
        try usdxPermit.permit(msg.sender, address(this), usdxAmount, _deadline, _v, _r, _s) {} catch {}
        _deposit(msg.sender, _receiver, usdxAmount, _wsUSDXAmount);

        return usdxAmount;
    }

    function withdraw(uint256 _usdxAmount, address _receiver, address _owner) public returns (uint256 wsUSDXAmount) {
        uint256 maxUsdxAmount = maxWithdraw(_owner);
        if (_usdxAmount > maxUsdxAmount) revert ExceededMaxWithdraw(_owner, _usdxAmount, maxUsdxAmount);

        wsUSDXAmount = previewWithdraw(_usdxAmount);
        _withdraw(msg.sender, _receiver, _owner, _usdxAmount, wsUSDXAmount);

        return wsUSDXAmount;
    }

    function withdraw(uint256 _usdxAmount) external returns (uint256 wsUSDXAmount) {
        return withdraw(_usdxAmount, msg.sender, msg.sender);
    }

    function redeem(uint256 _wsUSDXAmount, address _receiver, address _owner) public returns (uint256 usdxAmount) {
        uint256 maxWsUSDXAmount = maxRedeem(_owner);
        if (_wsUSDXAmount > maxWsUSDXAmount) revert ExceededMaxRedeem(_owner, _wsUSDXAmount, maxWsUSDXAmount);

        usdxAmount = previewRedeem(_wsUSDXAmount);
        _withdraw(msg.sender, _receiver, _owner, usdxAmount, _wsUSDXAmount);

        return usdxAmount;
    }

    function redeem(uint256 _wsUSDXAmount) external returns (uint256 usdxAmount) {
        return redeem(_wsUSDXAmount, msg.sender, msg.sender);
    }

    function wrap(uint256 _sUSDXAmount, address _receiver) public returns (uint256 wsUSDXAmount) {
        _assertNonZero(_sUSDXAmount);

        wsUSDXAmount = convertToShares(_sUSDXAmount);
        IERC20(sUSDXAddress).safeTransferFrom(msg.sender, address(this), _sUSDXAmount);
        _mint(_receiver, wsUSDXAmount);

        emit Wrap(msg.sender, _receiver, _sUSDXAmount, wsUSDXAmount);

        return wsUSDXAmount;
    }

    function wrap(uint256 _sUSDXAmount) external returns (uint256 wsUSDXAmount) {
        return wrap(_sUSDXAmount, msg.sender);
    }

    function wrapWithPermit(
        uint256 _sUSDXAmount,
        address _receiver,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (uint256 wsUSDXAmount) {
        IERC20Permit sUSDXPermit = IERC20Permit(sUSDXAddress);
        // the use of `try/catch` allows the permit to fail and makes the code tolerant to frontrunning.
        // solhint-disable-next-line no-empty-blocks
        try sUSDXPermit.permit(msg.sender, address(this), _sUSDXAmount, _deadline, _v, _r, _s) {} catch {}
        return wrap(_sUSDXAmount, _receiver);
    }

    function unwrap(uint256 _wsUSDXAmount, address _receiver) public returns (uint256 sUSDXAmount) {
        _assertNonZero(_wsUSDXAmount);

        IERC20Rebasing sUSDX = IERC20Rebasing(sUSDXAddress);

        uint256 sUSDXSharesAmount = _wsUSDXAmount * SUSDX_SHARES_OFFSET;
        sUSDXAmount = sUSDX.convertToUnderlyingToken(sUSDXSharesAmount);
        _burn(msg.sender, _wsUSDXAmount);
        // slither-disable-next-line unused-return
        sUSDX.transferShares(_receiver, sUSDXSharesAmount);

        emit Unwrap(msg.sender, _receiver, sUSDXAmount, _wsUSDXAmount);

        return sUSDXAmount;
    }

    function unwrap(uint256 _wsUSDXAmount) external returns (uint256 sUSDXAmount) {
        return unwrap(_wsUSDXAmount, msg.sender);
    }

    function _withdraw(
        address _caller,
        address _receiver,
        address _owner,
        uint256 _usdxAmount,
        uint256 _wsUSDXAmount
    ) internal {
        if (_caller != _owner) {
            _spendAllowance(_owner, _caller, _wsUSDXAmount);
        }

        IStUSDX sUSDX = IStUSDX(sUSDXAddress);

        sUSDX.withdraw(_usdxAmount, _receiver);
        _burn(_owner, _wsUSDXAmount);

        emit Withdraw(msg.sender, _receiver, _owner, _usdxAmount, _wsUSDXAmount);
    }

    function _deposit(
        address _caller,
        address _receiver,
        uint256 _usdxAmount,
        uint256 _wsUSDXAmount
    ) internal {
        IStUSDX sUSDX = IStUSDX(sUSDXAddress);
        IERC20 usdx = IERC20(usdxAddress);

        usdx.safeTransferFrom(_caller, address(this), _usdxAmount);
        sUSDX.deposit(_usdxAmount);
        _mint(_receiver, _wsUSDXAmount);

        emit Deposit(_caller, _receiver, _usdxAmount, _wsUSDXAmount);
    }

    function _assertNonZero(address _address) internal pure {
        if (_address == address(0)) revert ZeroAddress();
    }

    function _assertNonZero(uint256 _amount) internal pure {
        if (_amount == 0) revert InvalidAmount(_amount);
    }
}