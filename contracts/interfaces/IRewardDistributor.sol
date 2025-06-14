// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IDefaultErrors} from "./IDefaultErrors.sol";

interface IRewardDistributor is IDefaultErrors {

    event RewardDistributed(
        bytes32 indexed idempotencyKey,
        uint256 totalShares,
        uint256 totalUSDXBefore,
        uint256 totalUSDXAfter,
        uint256 stakingReward,
        uint256 feeReward
    );
    event FeeCollectorSet(address feeCollector);
    event VaultAdded(address indexed vault, address indexed asset, uint256 allocation, string vaultType);
    event VaultRemoved(address indexed vault);
    event TreasurySet(address indexed treasury);
    event ChainlinkOracleSet(address indexed chainlinkOracle);

    function distributeYield(bytes32 idempotencyKey, uint256 _feeReward) external;

    function getAccruedYield() external view returns (uint256 totalYield);

    function addSiloVault(address _vault, address _asset, uint256 _allocation) external;

    function addEulerVault(address _vault, address _asset, uint256 _allocation) external;

    function removeVault(address _vault) external;

    function setFeeCollector(address _feeCollectorAddress) external;

    function setTreasury(address _treasury) external;

    function setChainlinkOracle(address _chainlinkOracle) external;

    function pause() external;

    function unpause() external;

}