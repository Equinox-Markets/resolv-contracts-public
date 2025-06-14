// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20RebasingPermitUpgradeable} from "./ERC20RebasingPermitUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStUSDX} from "./interfaces/IStUSDX.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StUSDX is ERC20RebasingPermitUpgradeable, IStUSDX {
    using Math for uint256;
    using SafeERC20 for IERC20Metadata;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _name,
        string memory _symbol,
        address _usdxAddress
    ) public initializer {
        __ERC20Rebasing_init(_name, _symbol, _usdxAddress);
        __ERC20RebasingPermit_init(_name);
    }

    function deposit(uint256 _usdxAmount, address _receiver) public {
        uint256 shares = previewDeposit(_usdxAmount);
        //slither-disable-next-line incorrect-equality
        if (shares == 0) revert InvalidDepositAmount(_usdxAmount);

        IERC20Metadata usdx = super.underlyingToken();
        super._mint(_receiver, shares);
        usdx.safeTransferFrom(msg.sender, address(this), _usdxAmount);
        emit Deposit(msg.sender, _receiver, _usdxAmount, shares);
    }

    function deposit(uint256 _usdxAmount) external {
        deposit(_usdxAmount, msg.sender);
    }

    function depositWithPermit(
        uint256 _usdxAmount,
        address _receiver,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) public {
        IERC20Metadata usdx = super.underlyingToken();
        IERC20Permit usdxPermit = IERC20Permit(address(usdx));
        // the use of `try/catch` allows the permit to fail and makes the code tolerant to frontrunning.
        // solhint-disable-next-line no-empty-blocks
        try usdxPermit.permit(msg.sender, address(this), _usdxAmount, _deadline, _v, _r, _s) {} catch {}
        deposit(_usdxAmount, _receiver);
    }

    function depositWithPermit(
        uint256 _usdxAmount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        depositWithPermit(_usdxAmount, msg.sender, _deadline, _v, _r, _s);
    }

    function withdraw(uint256 _usdxAmount) external {
        withdraw(_usdxAmount, msg.sender);
    }

    function withdrawAll() external {
        withdraw(super.balanceOf(msg.sender), msg.sender);
    }

    function withdraw(uint256 _usdxAmount, address _receiver) public {
        uint256 shares = previewWithdraw(_usdxAmount);
        super._burn(msg.sender, shares);

        IERC20Metadata usdx = super.underlyingToken();
        usdx.safeTransfer(_receiver, _usdxAmount);
        emit Withdraw(msg.sender, _receiver, _usdxAmount, shares);
    }

    function previewDeposit(uint256 _usdxAmount) public view returns (uint256 shares) {
        return _convertToShares(_usdxAmount, Math.Rounding.Floor);
    }

    function previewWithdraw(uint256 _usdxAmount) public view returns (uint256 shares) {
        return _convertToShares(_usdxAmount, Math.Rounding.Ceil);
    }
}