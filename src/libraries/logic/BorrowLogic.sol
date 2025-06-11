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

    // ============ Common Internal Functions ============

    /**
     * @notice Update protocol indices
     */
    function _updateIndices(
        address predictionAsset,
        Storage.ReserveData storage reserve 
    ) private {
        console.log("       1.1 _updateIndices");
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        

        console.log("       1.2. reserve.variableBorrowIndex: ", reserve.variableBorrowIndex);

        (uint256 newBorrowIndex, uint256 newLiquidityIndex) = Core.updateIndices(
            Core.UpdateIndicesInput({
                reserve: reserve,
                riskParams: rp
            })
        );
        console.log("       1.3. newBorrowIndex: ", newBorrowIndex);
        reserve.variableBorrowIndex = newBorrowIndex;
        reserve.liquidityIndex = newLiquidityIndex;
        reserve.lastUpdateTimestamp = block.timestamp;
    }

    /**
     * @notice Calculate maximum borrowable amount for given collateral
     */
    function _calculateMaxBorrowable(uint256 collateralAmount, address predictionAsset) private view returns (uint256) {
        if (collateralAmount == 0) return 0;
        
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        
        uint256 currentPriceRay = IOracle(rp.priceOracle).getCurrentPrice(predictionAsset);
        
        uint result = Core.calculateBorrowAble(
            Core.CalcMaxBorrowInput({
                collateralAmount: collateralAmount,
                collateralPrice: currentPriceRay,
                ltv: rp.ltv,
                supplyAssetDecimals: rp.supplyAssetDecimals,
                collateralAssetDecimals: rp.collateralAssetDecimals
            })
        );
        console.log("       1.4. collateralAmount",collateralAmount);
        console.log("       1.5. currentPriceRay",currentPriceRay);
        console.log("       1.6. rp.ltv",rp.ltv);
        console.log("       1.7. rp.supplyAssetDecimals",rp.supplyAssetDecimals);
        console.log("       1.8. rp.collateralAssetDecimals",rp.collateralAssetDecimals);
        console.log("       1.9. result",result);   
        return result;
    }

    /**
     * @notice Execute deposit of collateral
     */
    function _executeDeposit(
        address user, 
        uint256 collateralAmount, 
        address predictionAsset,
        Storage.ReserveData storage reserve,
        Storage.UserPosition storage position
    ) private {
        console.log("       2.1. _executeDeposit");
        console.log("       2.2. reserve.totalCollateral: ", reserve.totalCollateral);
        console.log("       2.3. position.collateralAmount: ", position.collateralAmount);

        // Transfer collateral
        IERC20(predictionAsset).safeTransferFrom(user, address(this), collateralAmount);
        // Update accounting
        reserve.totalCollateral += collateralAmount;
        position.collateralAmount += collateralAmount;

        console.log("       2.4. reserve.totalCollateral: ", reserve.totalCollateral);
        console.log("       2.5. position.collateralAmount: ", position.collateralAmount);

    }

    /**
     * @notice Execute borrow operation
     */
    function _executeBorrow(
        address borrower, 
        uint256 borrowAmount, 
        address predictionAsset,
        Storage.UserPosition storage position,
        Storage.ReserveData storage reserve
    ) private returns (uint256) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;

        console.log("       3.1. _executeBorrow");
        console.log("       3.2. borrowAmount: ", borrowAmount);
        console.log("       3.3. rp.interestRateMode: ",rp.liquidityLayer);
        console.log("       3.4. rp.totalsupplu: ",reserve.totalScaledSupplied);
        console.log("       3.5. rp.totalborrowed: ",reserve.totalBorrowed);
        // Borrow from Aave and transfer to user
        ILiquidityLayer(rp.liquidityLayer).borrow(rp.supplyAsset, borrowAmount, rp.interestRateMode, address(this));
        console.log("       3.4. Borrowed amount transferred to borrower: ", borrowAmount);
        // Transfer borrowed amount to borrower
        IERC20(rp.supplyAsset).safeTransfer(borrower, borrowAmount);

        // Update accounting
        uint256 scaledBorrowed = Core.calculateScaledValue(borrowAmount, reserve.variableBorrowIndex);
        reserve.totalBorrowed += borrowAmount;
        position.borrowAmount += borrowAmount;
        position.scaledDebtBalance += scaledBorrowed;
        reserve.totalScaledBorrowed += scaledBorrowed;

        return borrowAmount;
    }

    // ============ Public Interface Functions ============

    /**
     * @notice Deposit collateral without borrowing
     */
    function deposit(
        address user, 
        uint256 collateralAmount, 
        address predictionAsset,
        Storage.UserPosition storage position,
        Storage.ReserveData storage reserve
    ) internal {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;

        if (!rp.isActive) revert PolynanceEE.MarketNotActive();
        if (collateralAmount == 0) revert PolynanceEE.InvalidAmount();

        _updateIndices(predictionAsset, reserve);
        _executeDeposit(user, collateralAmount, predictionAsset, reserve, position);
    }

    /**
     * @notice Borrow against existing collateral
     */
    function borrow(
        Storage.UserPosition storage position,
        Storage.ReserveData storage reserve,
        address predictionAsset,
        uint256 borrowAmount, 
        address borrower
    ) internal returns (uint256 borrowedAmount) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;

        if (!rp.isActive) revert PolynanceEE.MarketNotActive();
        if (position.collateralAmount == 0) revert PolynanceEE.InsufficientCollateral();

        _updateIndices(predictionAsset, reserve);

        console.log("       4.1. position.collateralAmount: ", position.collateralAmount);

        // Validate borrowing capacity
        uint256 maxBorrowForUser = _calculateMaxBorrowable(position.collateralAmount, predictionAsset);
        borrowAmount = borrowAmount == 0 ? maxBorrowForUser : borrowAmount;
        if (borrowAmount > maxBorrowForUser) revert PolynanceEE.InsufficientCollateral();

        // Validate liquidity
        uint256 totalPolynanceSupply = reserve.totalScaledSupplied.rayMul(reserve.liquidityIndex);
        uint256 currentTotalBorrowed = reserve.totalScaledBorrowed.rayMul(reserve.variableBorrowIndex);
        uint256 newTotalBorrowed = currentTotalBorrowed + borrowAmount;
        
        if (!Core.validateBorrow(newTotalBorrowed, totalPolynanceSupply, borrowAmount, maxBorrowForUser)) {
            revert PolynanceEE.InsufficientLiquidity();
        }

        return _executeBorrow(borrower, borrowAmount, predictionAsset, position, reserve);
    }

    /**
     * @notice Get the maximum amount a user can borrow based on their collateral
     */
    function getBorrowingCapacity(
        address user, 
        address predictionAsset,
        Storage.UserPosition storage position,
        Storage.ReserveData storage reserve
    ) internal view returns (uint256 maxBorrowable) {
        return _calculateMaxBorrowable(position.collateralAmount, predictionAsset);
    }

    /**
     * @notice Original borrow function that deposits collateral and borrows in one transaction
     */
    function depositAndBorrow(
        address borrower, 
        uint256 collateralAmount, 
        address predictionAsset,
        Storage.UserPosition storage position,
        Storage.ReserveData storage reserve
    ) internal returns (uint256 borrowedAmount) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;

        if (!rp.isActive) revert PolynanceEE.MarketNotActive();
        if (collateralAmount == 0) revert PolynanceEE.InvalidAmount();
        console.log("   1.");
        _updateIndices(predictionAsset, reserve);
        console.log("   2. _updateIndices");
        _executeDeposit(borrower, collateralAmount, predictionAsset, reserve, position);
        console.log("   3. _executeDeposit");
        
        uint256 maxBorrowForUser = _calculateMaxBorrowable(collateralAmount, predictionAsset);
        return _executeBorrow(borrower, maxBorrowForUser, predictionAsset, position, reserve);
    }

    /**
     * @notice Repay borrowed amount
     */
    function repay(
        address borrower, 
        address predictionAsset,
        Storage.UserPosition storage position,
        Storage.ReserveData storage reserve
    ) internal returns (uint256 repaidAmount) {
        console.log("       [REPAY] 1. repay");
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        
        if (position.scaledDebtBalance == 0) revert PolynanceEE.NoDebtToRepay();

        
        uint256 userDebtShare = position.scaledDebtBalance.percentDiv(reserve.totalScaledBorrowed);

        console.log("       [REPAY] 1.1. position.scaledDebtBalance: ", position.scaledDebtBalance);
        console.log("       [REPAY] 1.2. reserve.variableBorrowIndex: ", reserve.variableBorrowIndex);
        console.log("       [REPAY] 1.3. position.borrowAmount: ", position.borrowAmount);
       

        _updateIndices(predictionAsset, reserve);
        
        
        reserve.totalScaledBorrowed -= position.scaledDebtBalance;  
        reserve.totalBorrowed -= position.borrowAmount;

        console.log("       [REPAY] 3. reserve.accumulatedSpread: ", reserve.accumulatedSpread);
        console.log("       [REPAY] 4. reserve.totalScaledBorrowed: ", reserve.totalScaledBorrowed);
        console.log("       [REPAY] 5. reserve.totalBorrowed: ", reserve.totalBorrowed);

        // Calculate user's share of the Aave debt using scaled balance

        console.log("       [REPAY] 3. userDebtShare: ", userDebtShare);
        
        // Calculate user's total debt including spread interest
        console.log("       [REPAY] userDebtShare: ", userDebtShare);
        (uint256 userTotalDebt, uint256 principalDebt,uint256 spread) = Core.calculateUserTotalDebt(
            Core.CalcUserTotalDebtInput({
                principalDebt: ILiquidityLayer(rp.liquidityLayer).getTotalDebt(rp.supplyAsset, address(this)).percentMul(userDebtShare),
                scaledPolynanceSpreadDebtPrincipal: position.scaledDebtBalance,
                initialBorrowAmount: position.borrowAmount,
                currentPolynanceSpreadBorrowIndex: reserve.variableBorrowIndex
            })
        );

        reserve.accumulatedSpread += spread;
        console.log("       [REPAY] 5. userTotalDebt: ", userTotalDebt);
        console.log("       [REPAY] 5. principalDebt: ", principalDebt);
        console.log("       [REPAY] 5. spread: ", spread);
        console.log("       [REPAY] 5. reserve.totalScaledBorrowed: ", reserve.totalScaledBorrowed);
        console.log("       [REPAY] 5. reserve.totalBorrowed: ", reserve.totalBorrowed);
        console.log("       [REPAY] 6. reserve.accumulatedSpread: ", reserve.accumulatedSpread);

        console.log("       [REPAY] userTotalDebt: ", userTotalDebt);
        repaidAmount = userTotalDebt;

        // Transfer repay amount and repay to Aave
        IERC20(rp.supplyAsset).safeTransferFrom(borrower, address(this), repaidAmount);
        console.log("       [REPAY] repaidAmount: ", repaidAmount);
        ILiquidityLayer(rp.liquidityLayer).repay(rp.supplyAsset, principalDebt, rp.interestRateMode, address(this));

        console.log("       [REPAY] repaidAmount: ", repaidAmount);

        // Clear user position and return collateral
        position.borrowAmount = 0;
        position.scaledDebtBalance = 0;

        if (position.collateralAmount > 0) {
            uint256 collateralToReturn = position.collateralAmount;
            position.collateralAmount = 0;
            reserve.totalCollateral = reserve.totalCollateral > collateralToReturn ? 
                reserve.totalCollateral - collateralToReturn : 0;
            IERC20(predictionAsset).safeTransfer(borrower, collateralToReturn);
        }

        return repaidAmount;
    }
}