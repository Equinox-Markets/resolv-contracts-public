// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ISimpleToken} from "./interfaces/ISimpleToken.sol";

contract SimpleToken is ISimpleToken, Initializable, ERC20PermitUpgradeable, AccessControlDefaultAdminRulesUpgradeable {

    bytes32 public constant SERVICE_ROLE = keccak256("SERVICE_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    mapping(bytes32 => bool) private mintIds;
    mapping(bytes32 => bool) private burnIds;

    modifier idempotentMint(bytes32 idempotencyKey) {
        if (mintIds[idempotencyKey]) {
            revert IdempotencyKeyAlreadyExist(idempotencyKey);
        }
        _;
        mintIds[idempotencyKey] = true;
    }

    modifier idempotentBurn(bytes32 idempotencyKey) {
        if (burnIds[idempotencyKey]) {
            revert IdempotencyKeyAlreadyExist(idempotencyKey);
        }
        _;
        burnIds[idempotencyKey] = true;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _name,
        string memory _symbol
    ) public initializer {
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);

        __AccessControlDefaultAdminRules_init(1 days, msg.sender);
    }

    function mint(address _account, uint256 _amount) external onlyRole(SERVICE_ROLE) {
        _mint(_account, _amount);
    }

    function mint(bytes32 _idempotencyKey, address _account, uint256 _amount) external
    onlyRole(SERVICE_ROLE) idempotentMint(_idempotencyKey) {
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external {
        if (hasRole(SERVICE_ROLE, msg.sender)) {
            // Service role can burn from any account
            _burn(_account, _amount);
        } else if (hasRole(TREASURY_ROLE, msg.sender)) {
            // Treasury role can burn from any account (for redemptions)
            _burn(_account, _amount);
        } else if (msg.sender == _account) {
            // Users can burn their own tokens
            _burn(_account, _amount);
        } else {
            // Check if caller has sufficient allowance
            uint256 currentAllowance = allowance(_account, msg.sender);
            if (currentAllowance < _amount) {
                revert ERC20InsufficientAllowance(msg.sender, currentAllowance, _amount);
            }
            _spendAllowance(_account, msg.sender, _amount);
            _burn(_account, _amount);
        }
    }

    function burn(bytes32 _idempotencyKey, address _account, uint256 _amount) external
    onlyRole(SERVICE_ROLE) idempotentBurn(_idempotencyKey) {
        _burn(_account, _amount);
    }

    /**
     * @dev Burns tokens from caller's account
     * @param _amount Amount to burn
     */
    function burn(uint256 _amount) external {
        _burn(msg.sender, _amount);
    }

    /**
     * @dev Burns tokens from account using allowance mechanism
     * @param _account Account to burn from
     * @param _amount Amount to burn
     */
    function burnFrom(address _account, uint256 _amount) external {
        uint256 currentAllowance = allowance(_account, msg.sender);
        if (currentAllowance < _amount) {
            revert ERC20InsufficientAllowance(msg.sender, currentAllowance, _amount);
        }
        _spendAllowance(_account, msg.sender, _amount);
        _burn(_account, _amount);
    }
}