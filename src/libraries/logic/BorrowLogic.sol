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
import {PercentageMath} from "@aave/protocol/libraries/math/PercentageMath.sol";
import "../PolynanceEE.sol";

library BorrowLogic {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;
    using PercentageMath for uint256;


    function borrow(address borrower, uint256 collateralAmount,address predictionAsset) internal returns (uint256 borrowedAmount) {
        // Load storage shortcuts
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;

        // Basic checks
        if (!rp.isActive) revert PolynanceEE.MarketNotActive();
        if (collateralAmount == 0) revert PolynanceEE.InvalidAmount();

        // Move collateral from borrower to this contract
        IERC20(predictionAsset).safeTransferFrom(borrower, address(this), collateralAmount);

        // Identify market and reserve data
        Storage.ReserveData storage reserve = Core.getReserveData(Core.getMarketId(predictionAsset, rp.supplyAsset));
        Storage.UserPosition storage position = Core.getUserPosition(Core.getMarketId(predictionAsset, rp.supplyAsset), borrower);


        // Update Polynance indices before any state-changing math
        (uint256 newBorrowIndex, uint256 newLiquidityIndex) = Core.updateIndices(
            Core.UpdateIndicesInput({
                reserve: reserve,
                riskParams: rp
            })
        );
        reserve.variableBorrowIndex = newBorrowIndex;
        reserve.liquidityIndex = newLiquidityIndex;
        reserve.lastUpdateTimestamp = block.timestamp;

        // ---------- Calculate max borrow amount ----------
        // Fetch collateral valuation from oracle (denominated in the supply asset)
        uint256 currentPriceRay = IOracle(rp.priceOracle).getCurrentPrice(predictionAsset).wadToRay();
        uint256 maxBorrowForUser = Core.calculateBorrowAble(
            Core.CalcMaxBorrowInput({
                collateralAmount: collateralAmount,
                collateralPrice: currentPriceRay,
                ltv: rp.ltv,
                supplyAssetDecimals: rp.supplyAssetDecimals,
                collateralAssetDecimals: rp.collateralAssetDecimals
            })
        );

        borrowedAmount = maxBorrowForUser;

        // ---------- Interact with underlying liquidity layer (Aave) ----------
        ILiquidityLayer(rp.aaveModule).borrow(rp.supplyAsset, borrowedAmount, rp.interestRateMode, address(this));

        // Send borrowed funds to user
        IERC20(rp.supplyAsset).safeTransfer(borrower, borrowedAmount);

        uint256 scaledBorrowed = Core.calculateScaledValue(borrowedAmount, reserve.variableBorrowIndex);
        // ---------- Update protocol accounting ----------
        reserve.totalScaledBorrowed += scaledBorrowed;
        reserve.totalCollateral += collateralAmount;
        reserve.totalBorrowed += borrowedAmount;

        // Update user position
        position.collateralAmount += collateralAmount;
        position.borrowAmount += borrowedAmount;
        position.scaledDebtBalance += scaledBorrowed;

        return borrowedAmount;
    }

    function repay(address borrower, uint256 amount, address predictionAsset) internal returns (uint256 repaidAmount) {
        // Load storage shortcuts
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;

        // Basic checks
        if (amount == 0) revert PolynanceEE.InvalidAmount();

        // Identify market and reserve data
        Storage.ReserveData storage reserve = Core.getReserveData(Core.getMarketId(predictionAsset, rp.supplyAsset));
        Storage.UserPosition storage position = Core.getUserPosition(Core.getMarketId(predictionAsset, rp.supplyAsset), borrower);

        // Check if user has any debt
        if (position.scaledDebtBalance == 0) revert PolynanceEE.NoDebtToRepay();

        uint256 spreadAtThisRepay = position.scaledDebtBalance.rayMul(reserve.variableBorrowIndex) - position.borrowAmount;

        // Update Polynance indices before calculations
        (uint256 newBorrowIndex, uint256 newLiquidityIndex) = Core.updateIndices(
            Core.UpdateIndicesInput({
                reserve: reserve,
                riskParams: rp
            })
        );
        reserve.variableBorrowIndex = newBorrowIndex;
        reserve.liquidityIndex = newLiquidityIndex;
        reserve.accumulatedSpread += spreadAtThisRepay;
        reserve.lastUpdateTimestamp = block.timestamp;
        reserve.totalScaledBorrowed -= position.scaledDebtBalance;  
        reserve.totalBorrowed -= position.borrowAmount;

        // Calculate user's share of the Aave debt using scaled balance
        uint256 userDebtShare = position.scaledDebtBalance.percentDiv(reserve.totalScaledBorrowed);
        // Calculate user's total debt including spread interest
        (uint256 userTotalDebt, uint256 principalDebt,) = Core.calculateUserTotalDebt(
            Core.CalcUserTotalDebtInput({
                principalDebt: ILiquidityLayer(rp.aaveModule).getTotalDebt(rp.supplyAsset,address(this)).percentMul(userDebtShare),
                scaledPolynanceSpreadDebtPrincipal: position.scaledDebtBalance,
                initialBorrowAmount: position.borrowAmount,
                currentPolynanceSpreadBorrowIndex: reserve.variableBorrowIndex
            })
        );

        // Lump-sum repayment only - amount must equal total debt
        if (amount != userTotalDebt) revert PolynanceEE.InvalidAmount();
        repaidAmount = userTotalDebt;

        // Transfer repay amount from borrower
        IERC20(rp.supplyAsset).safeTransferFrom(borrower, address(this), repaidAmount);


        // Repay to Aave (only principal debt)
        ILiquidityLayer(rp.aaveModule).repay(
            rp.supplyAsset, 
            principalDebt, 
            rp.interestRateMode, 
            address(this)
        );

        // Clear user position completely
        position.borrowAmount = 0;
        position.scaledDebtBalance = 0;

        // Return all collateral
        if (position.collateralAmount > 0) {
            uint256 collateralToReturn = position.collateralAmount;
            position.collateralAmount = 0;
            reserve.totalCollateral = reserve.totalCollateral > collateralToReturn ? 
                reserve.totalCollateral - collateralToReturn : 0;
            IERC20(predictionAsset).safeTransfer(borrower, collateralToReturn);
            // emit PolynanceEE.CollateralReturned(borrower, collateralToReturn);
        }


    }

    

}