// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IUSDXRedemptionExtension {
    
    event RedemptionCalculated(
        address indexed user,
        address indexed asset,
        uint256 usdxAmount,
        uint256 assetAmount,
        uint256 priceAdjustment
    );
    event ChainlinkOracleSet(address indexed oracle);
    event MaxRedemptionPerBlockSet(uint256 maxAmount);
    event RedeemableAssetSet(address indexed asset, bool isRedeemable);
    event VaultConfigurationUpdated(address indexed vault, uint256 allocation, bool isActive);
    
    error UnsupportedAsset(address asset);
    error InvalidRedemptionAmount(uint256 amount);
    error ExceedsBlockLimit(uint256 requested, uint256 limit);
    error InsufficientLiquidity(uint256 required, uint256 available);
    error OracleDataStale(uint256 lastUpdate, uint256 threshold);
    
    struct VaultInfo {
        address vault;
        address connector;
        uint256 allocation;
        bool isActive;
        string protocol;
    }
    
    function computeRedemption(
        address _asset,
        uint256 _usdxAmount
    ) external view returns (uint256 assetAmount, uint256 priceAdjustment);
    
    function validateRedemption(
        address _user,
        address _asset,
        uint256 _usdxAmount,
        uint256 _minAssetAmount,
        uint256 _blockNumber
    ) external view returns (bool isValid, string memory reason);
    
    function calculateWithdrawalPlan(
        uint256 _requiredAmount
    ) external view returns (VaultInfo[] memory withdrawalPlan, uint256 totalAvailable);
    
    function getRedemptionQuote(
        address _asset,
        uint256 _usdxAmount
    ) external view returns (
        uint256 assetAmount,
        uint256 priceAdjustment,
        bool isPriceAdjusted,
        string memory priceSource
    );
}