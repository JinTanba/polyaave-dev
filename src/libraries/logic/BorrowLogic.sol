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
    function _updateIndices(address predictionAsset) private {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(predictionAsset, rp.supplyAsset);
        Storage.ReserveData storage reserve = Core.getReserveData(marketId);

        (uint256 newBorrowIndex, uint256 newLiquidityIndex) = Core.updateIndices(
            Core.UpdateIndicesInput({
                reserve: reserve,
                riskParams: rp
            })
        );
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
        
        uint256 currentPriceRay = IOracle(rp.priceOracle).getCurrentPrice(predictionAsset).wadToRay();
        
        return Core.calculateBorrowAble(
            Core.CalcMaxBorrowInput({
                collateralAmount: collateralAmount,
                collateralPrice: currentPriceRay,
                ltv: rp.ltv,
                supplyAssetDecimals: rp.supplyAssetDecimals,
                collateralAssetDecimals: rp.collateralAssetDecimals
            })
        );
    }

    /**
     * @notice Execute deposit of collateral
     */
    function _executeDeposit(address user, uint256 collateralAmount, address predictionAsset) private {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(predictionAsset, rp.supplyAsset);
        Storage.ReserveData storage reserve = Core.getReserveData(marketId);
        Storage.UserPosition storage position = Core.getUserPosition(marketId, user);

        // Transfer collateral
        IERC20(predictionAsset).safeTransferFrom(user, address(this), collateralAmount);
        
        // Update accounting
        reserve.totalCollateral += collateralAmount;
        position.collateralAmount += collateralAmount;
    }

    /**
     * @notice Execute borrow operation
     */
    function _executeBorrow(address borrower, uint256 borrowAmount, address predictionAsset) private returns (uint256) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(predictionAsset, rp.supplyAsset);
        Storage.ReserveData storage reserve = Core.getReserveData(marketId);
        Storage.UserPosition storage position = Core.getUserPosition(marketId, borrower);

        // Borrow from Aave and transfer to user
        ILiquidityLayer(rp.liquidityLayer).borrow(rp.supplyAsset, borrowAmount, rp.interestRateMode, address(this));
        IERC20(rp.supplyAsset).safeTransfer(borrower, borrowAmount);

        // Update accounting
        uint256 scaledBorrowed = Core.calculateScaledValue(borrowAmount, reserve.variableBorrowIndex);
        reserve.totalScaledBorrowed += scaledBorrowed;
        reserve.totalBorrowed += borrowAmount;
        position.borrowAmount += borrowAmount;
        position.scaledDebtBalance += scaledBorrowed;

        return borrowAmount;
    }

    // ============ Public Interface Functions ============

    /**
     * @notice Deposit collateral without borrowing
     */
    function deposit(address user, uint256 collateralAmount, address predictionAsset) internal {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;

        if (!rp.isActive) revert PolynanceEE.MarketNotActive();
        if (collateralAmount == 0) revert PolynanceEE.InvalidAmount();

        _updateIndices(predictionAsset);
        _executeDeposit(user, collateralAmount, predictionAsset);
    }

    /**
     * @notice Borrow against existing collateral
     */
    function borrow(address borrower, uint256 borrowAmount, address predictionAsset) internal returns (uint256 borrowedAmount) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(predictionAsset, rp.supplyAsset);
        Storage.ReserveData storage reserve = Core.getReserveData(marketId);
        Storage.UserPosition storage position = Core.getUserPosition(marketId, borrower);

        if (!rp.isActive) revert PolynanceEE.MarketNotActive();
        if (borrowAmount == 0) revert PolynanceEE.InvalidAmount();
        if (position.collateralAmount == 0) revert PolynanceEE.InsufficientCollateral();

        _updateIndices(predictionAsset);

        // Validate borrowing capacity
        uint256 maxBorrowForUser = _calculateMaxBorrowable(position.collateralAmount, predictionAsset);
        if (borrowAmount > maxBorrowForUser) revert PolynanceEE.InsufficientCollateral();

        // Validate liquidity
        uint256 totalPolynanceSupply = reserve.totalScaledSupplied.rayMul(reserve.liquidityIndex);
        uint256 currentTotalBorrowed = reserve.totalScaledBorrowed.rayMul(reserve.variableBorrowIndex);
        uint256 newTotalBorrowed = currentTotalBorrowed + borrowAmount;
        
        if (!Core.validateBorrow(newTotalBorrowed, totalPolynanceSupply, borrowAmount, maxBorrowForUser)) {
            revert PolynanceEE.InsufficientLiquidity();
        }

        return _executeBorrow(borrower, borrowAmount, predictionAsset);
    }

    /**
     * @notice Get the maximum amount a user can borrow based on their collateral
     */
    function getBorrowingCapacity(address user, address predictionAsset) internal view returns (uint256 maxBorrowable) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(predictionAsset, rp.supplyAsset);
        Storage.UserPosition storage position = Core.getUserPosition(marketId, user);
        
        return _calculateMaxBorrowable(position.collateralAmount, predictionAsset);
    }

    /**
     * @notice Original borrow function that deposits collateral and borrows in one transaction
     */
    function depositAndBorrow(address borrower, uint256 collateralAmount, address predictionAsset) internal returns (uint256 borrowedAmount) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;

        if (!rp.isActive) revert PolynanceEE.MarketNotActive();
        if (collateralAmount == 0) revert PolynanceEE.InvalidAmount();

        _updateIndices(predictionAsset);
        _executeDeposit(borrower, collateralAmount, predictionAsset);
        
        uint256 maxBorrowForUser = _calculateMaxBorrowable(collateralAmount, predictionAsset);
        return _executeBorrow(borrower, maxBorrowForUser, predictionAsset);
    }

    /**
     * @notice Repay borrowed amount
     */
    function repay(address borrower, uint256 amount, address predictionAsset) internal returns (uint256 repaidAmount) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(predictionAsset, rp.supplyAsset);
        Storage.ReserveData storage reserve = Core.getReserveData(marketId);
        Storage.UserPosition storage position = Core.getUserPosition(marketId, borrower);

        if (amount == 0) revert PolynanceEE.InvalidAmount();
        if (position.scaledDebtBalance == 0) revert PolynanceEE.NoDebtToRepay();

        uint256 spreadAtThisRepay = position.scaledDebtBalance.rayMul(reserve.variableBorrowIndex) - position.borrowAmount;

        _updateIndices(predictionAsset);
        
        reserve.accumulatedSpread += spreadAtThisRepay;
        reserve.totalScaledBorrowed -= position.scaledDebtBalance;  
        reserve.totalBorrowed -= position.borrowAmount;

        // Calculate user's share of the Aave debt using scaled balance
        uint256 userDebtShare = position.scaledDebtBalance.percentDiv(reserve.totalScaledBorrowed);
        
        // Calculate user's total debt including spread interest
        (uint256 userTotalDebt, uint256 principalDebt,) = Core.calculateUserTotalDebt(
            Core.CalcUserTotalDebtInput({
                principalDebt: ILiquidityLayer(rp.liquidityLayer).getTotalDebt(rp.supplyAsset, address(this)).percentMul(userDebtShare),
                scaledPolynanceSpreadDebtPrincipal: position.scaledDebtBalance,
                initialBorrowAmount: position.borrowAmount,
                currentPolynanceSpreadBorrowIndex: reserve.variableBorrowIndex
            })
        );

        if (amount != userTotalDebt) revert PolynanceEE.InvalidAmount();
        repaidAmount = userTotalDebt;

        // Transfer repay amount and repay to Aave
        IERC20(rp.supplyAsset).safeTransferFrom(borrower, address(this), repaidAmount);
        ILiquidityLayer(rp.liquidityLayer).repay(rp.supplyAsset, principalDebt, rp.interestRateMode, address(this));

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