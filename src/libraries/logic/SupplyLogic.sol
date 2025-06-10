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
    
    function supply(
        Storage.ReserveData storage reserve, 
        Storage.SupplyPosition storage position,
        address supplier,
        uint256 amount
    ) internal returns (uint256 shares) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams memory rp = $.riskParams;
        
        // Basic validation
        if (!rp.isActive) revert PolynanceEE.MarketNotActive();
        if (!Core.validateSupply(amount)) revert PolynanceEE.InvalidAmount();
        console.log("Supplying...");
        console.log("1. rp.supplyAsset: ", rp.supplyAsset);
        console.log("   amount: ", amount);
        


        // Update indices before any calculations
        (uint256 newBorrowIndex, uint256 newLiquidityIndex) = Core.updateIndices(
            Core.UpdateIndicesInput({
                reserve: reserve,
                riskParams: rp
            })
        );

        console.log("2. newBorrowIndex: ", newBorrowIndex);
        console.log("   newLiquidityIndex: ", newLiquidityIndex);
        
        
        // Update storage with new indices
        reserve.variableBorrowIndex = newBorrowIndex;
        reserve.liquidityIndex = newLiquidityIndex;
        reserve.lastUpdateTimestamp = block.timestamp;
        reserve.totalScaledSupplied += Core.calculateScaledValue(amount, newLiquidityIndex);

        console.log("3. reserve.variableBorrowIndex: ", reserve.variableBorrowIndex);
        console.log("   reserve.liquidityIndex: ", reserve.liquidityIndex);
        console.log("   reserve.lastUpdateTimestamp: ", reserve.lastUpdateTimestamp);
        console.log("   reserve.totalScaledSupplied: ", reserve.totalScaledSupplied);
        
        emit PolynanceEE.IndicesUpdated(newBorrowIndex, newLiquidityIndex);
        // supplier -> contract
        IERC20(rp.supplyAsset).safeTransferFrom(supplier, address(this), amount);
        console.log("4. supplier -> contract: ", amount);
        // contract -> aave
        ILiquidityLayer(rp.liquidityLayer).supply(rp.supplyAsset, amount, address(this));
        console.log("========================   5. contract -> aave",amount);
        // Calculate scaled balance for Polynance (tracks LP's share of spread earnings)
        uint256 scaledSupplyBalance = Core.calculateScaledValue(amount, newLiquidityIndex);
        console.log("6. scaledSupplyBalance: ", scaledSupplyBalance);
        // Get or create supply position
        position.supplyAmount += amount;
        position.scaledSupplyBalance += scaledSupplyBalance;
        console.log("7. position.supplyAmount: ", position.supplyAmount);
        console.log("   position.scaledSupplyBalance: ", position.scaledSupplyBalance);
        
        return amount;
    }
    
}