// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IChainlinkOracle} from "../interfaces/oracles/IChainlinkOracle.sol";
import {IERC4626Oracle} from "../interfaces/oracles/IERC4626Oracle.sol";

/// @title OracleLib
/// @notice Library to manage oracle operations for USDX yield calculation
library OracleLib {
    
    error OracleInvalidPrice();
    error OracleStalePrice();

    /**
     * @dev Get price and decimals from Chainlink oracle with heartbeat check
     * @param oracle The oracle address
     * @param heartBeat Maximum age of price data in seconds
     * @return price The price from oracle
     * @return decimals The decimal precision of the price
     */
    function getPriceAndDecimals(address oracle, uint256 heartBeat)
        internal
        view
        returns (int256 price, uint256 decimals)
    {
        IChainlinkOracle chainlinkOracle = IChainlinkOracle(oracle);
        uint8 oracleDecimals = chainlinkOracle.priceDecimals(oracle);
        (, int256 answer,, uint256 updatedAt,) = chainlinkOracle.getLatestRoundData(oracle);
        
        if (answer <= 0) {
            revert OracleInvalidPrice();
        }
        
        if (block.timestamp > updatedAt + heartBeat) {
            revert OracleStalePrice();
        }
        
        return (answer, oracleDecimals);
    }

    /**
     * @dev Try to update an ERC4626 oracle (for vault exchange rates)
     * @param _oracle The oracle address to update
     * @return isSuccess Whether the update was successful
     */
    function tryUpdateOracle(address _oracle) internal returns (bool isSuccess) {
        if (_oracle == address(0)) {
            return false;
        }
        
        IERC4626Oracle oracle = IERC4626Oracle(_oracle);
        try oracle.update() {
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @dev Get the latest exchange rate from an ERC4626 oracle
     * @param _oracle The oracle address
     * @return rate The exchange rate (assets per share)
     * @return decimals The decimal precision
     */
    function getExchangeRate(address _oracle) 
        internal 
        view 
        returns (uint256 rate, uint256 decimals) 
    {
        if (_oracle == address(0)) {
            return (1e18, 18); // Default 1:1 rate
        }
        
        IERC4626Oracle oracle = IERC4626Oracle(_oracle);
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        
        if (answer <= 0 || block.timestamp > updatedAt + 1 days) {
            return (1e18, 18); // Fallback to 1:1 rate
        }
        
        return (uint256(answer), oracle.decimals());
    }
}