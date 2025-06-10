// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../Storage.sol";
import "../../Core.sol";
import "../../interfaces/ILiquidityLayer.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IOracle} from "../../interfaces/Oralce.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "../PolynanceEE.sol";

library SupplyLogic {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    
    /**
     * @notice Execute supply operation
     * @param supplier Address of the supplier
     * @param amount Amount to supply
     * @param tokenId Token ID for the supply position
     * @return shares Amount of LP tokens minted
     */
    function supply(address supplier, uint256 amount, uint256 tokenId,address predictionAsset) internal returns (uint256 shares) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams memory rp = $.riskParams;
        
        // Basic validation
        if (!rp.isActive) revert PolynanceEE.MarketNotActive();
        if (!Core.validateSupply(amount)) revert PolynanceEE.InvalidAmount();
        
        // Get market data
        bytes32 marketId = Core.getMarketId(rp.supplyAsset, predictionAsset);
        Storage.ReserveData storage reserve = Core.getReserveData(marketId);
        
        
        // Update indices before any calculations
        (uint256 newBorrowIndex, uint256 newLiquidityIndex) = Core.updateIndices(
            Core.UpdateIndicesInput({
                reserve: reserve,
                riskParams: rp
            })
        );
        
        // Update storage with new indices
        reserve.variableBorrowIndex = newBorrowIndex;
        reserve.liquidityIndex = newLiquidityIndex;
        reserve.lastUpdateTimestamp = block.timestamp;
        reserve.totalScaledSupplied += Core.calculateScaledValue(amount, newLiquidityIndex);
        
        emit PolynanceEE.IndicesUpdated(newBorrowIndex, newLiquidityIndex);
        // supplier -> contract
        IERC20(rp.supplyAsset).safeTransferFrom(supplier, address(this), amount);
        // contract -> aave
        ILiquidityLayer(rp.aaveModule).supply(rp.supplyAsset, amount, address(this));
        // Calculate scaled balance for Polynance (tracks LP's share of spread earnings)
        uint256 scaledSupplyBalance = Core.calculateScaledValue(amount, newLiquidityIndex);
        // Get or create supply position
        Storage.SupplyPosition storage position = $.supplyPositions[tokenId];
        position.supplyAmount += amount;
        position.scaledSupplyBalance += scaledSupplyBalance;
        
        return amount;
    }
    
}