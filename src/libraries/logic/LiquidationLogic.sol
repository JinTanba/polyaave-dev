// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../Storage.sol";
import "../../Core.sol";
import "../../interfaces/ILiquidityLayer.sol";
import {IOracle} from "../../interfaces/Oralce.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/protocol/libraries/math/PercentageMath.sol";
import "../PolynanceEE.sol";

library LiquidationLogic {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    // ============ Events ============
    event LiquidationCall(
        address indexed collateralAsset,
        address indexed supplyAsset,
        address indexed user,
        uint256 debtToCover,
        uint256 liquidatedCollateralAmount,
        address liquidator,
        bool receiveCollateral
    );

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
     * @notice Calculate user's health factor
     */
    function _calculateHealthFactor(address user, address predictionAsset) private view returns (uint256) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(predictionAsset, rp.supplyAsset);
        Storage.ReserveData storage reserve = Core.getReserveData(marketId);
        Storage.UserPosition storage position = Core.getUserPosition(marketId, user);

        if (position.scaledDebtBalance == 0) {
            return type(uint256).max; // No debt means infinite health
        }

        // Get current price from oracle
        uint256 currentPriceRay = IOracle(rp.priceOracle).getCurrentPrice(predictionAsset).wadToRay();

        // Calculate total debt including Aave interest
        uint256 userDebtShare = position.scaledDebtBalance.percentDiv(reserve.totalScaledBorrowed);
        uint256 aavePrincipalDebt = ILiquidityLayer(rp.liquidityLayer).getTotalDebt(rp.supplyAsset, address(this)).percentMul(userDebtShare);
        
        (uint256 userTotalDebt,,) = Core.calculateUserTotalDebt(
            Core.CalcUserTotalDebtInput({
                principalDebt: aavePrincipalDebt,
                scaledPolynanceSpreadDebtPrincipal: position.scaledDebtBalance,
                initialBorrowAmount: position.borrowAmount,
                currentPolynanceSpreadBorrowIndex: reserve.variableBorrowIndex
            })
        );

        return Core.calculateHealthFactor(
            Core.CalcHealthFactorInput({
                collateralAmount: position.collateralAmount,
                collateralPrice: currentPriceRay,
                userTotalDebt: userTotalDebt,
                liquidationThreshold: rp.liquidationThreshold,
                supplyAssetDecimals: rp.supplyAssetDecimals,
                collateralAssetDecimals: rp.collateralAssetDecimals
            })
        );
    }

    /**
     * @notice Execute the liquidation
     */
    function _executeLiquidation(
        address liquidator,
        address user,
        uint256 debtToCover,
        address predictionAsset,
        bool receiveCollateral
    ) private returns (uint256 actualDebtCovered, uint256 collateralLiquidated) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(predictionAsset, rp.supplyAsset);
        Storage.ReserveData storage reserve = Core.getReserveData(marketId);
        Storage.UserPosition storage position = Core.getUserPosition(marketId, user);

        // Get current price
        uint256 currentPriceRay = IOracle(rp.priceOracle).getCurrentPrice(predictionAsset).wadToRay();

        // Calculate user's total debt
        uint256 userDebtShare = position.scaledDebtBalance.percentDiv(reserve.totalScaledBorrowed);
        uint256 aavePrincipalDebt = ILiquidityLayer(rp.liquidityLayer).getTotalDebt(rp.supplyAsset, address(this)).percentMul(userDebtShare);
        
        (uint256 userTotalDebt, uint256 principalDebt, uint256 spreadDebt) = Core.calculateUserTotalDebt(
            Core.CalcUserTotalDebtInput({
                principalDebt: aavePrincipalDebt,
                scaledPolynanceSpreadDebtPrincipal: position.scaledDebtBalance,
                initialBorrowAmount: position.borrowAmount,
                currentPolynanceSpreadBorrowIndex: reserve.variableBorrowIndex
            })
        );

        // Calculate liquidation amounts
        Core.LiquidationAmountsResult memory liquidationAmounts = Core.calculateLiquidationAmounts(
            Core.CalcLiquidationAmountsInput({
                userTotalDebt: userTotalDebt,
                collateralAmount: position.collateralAmount,
                collateralPrice: currentPriceRay,
                liquidationCloseFactor: rp.liquidationCloseFactor,
                liquidationBonus: rp.liquidationBonus,
                supplyAssetDecimals: rp.supplyAssetDecimals,
                collateralAssetDecimals: rp.collateralAssetDecimals
            })
        );

        actualDebtCovered = liquidationAmounts.debtToRepay;
        collateralLiquidated = liquidationAmounts.collateralToSeize;

        // Transfer debt payment from liquidator
        IERC20(rp.supplyAsset).safeTransferFrom(liquidator, address(this), actualDebtCovered);

        // Calculate how much goes to Aave vs spread
        uint256 principalToRepay = actualDebtCovered <= principalDebt ? actualDebtCovered : principalDebt;
        uint256 spreadRepaid = actualDebtCovered > principalDebt ? actualDebtCovered - principalDebt : 0;

        // Repay to Aave
        if (principalToRepay > 0) {
            ILiquidityLayer(rp.liquidityLayer).repay(rp.supplyAsset, principalToRepay, rp.interestRateMode, address(this));
        }

        // Update reserve accounting
        if (spreadRepaid > 0) {
            reserve.accumulatedSpread += spreadRepaid;
        }

        // Update position
        if (liquidationAmounts.isFullLiquidation) {
            // Full liquidation - clear position
            reserve.totalScaledBorrowed -= position.scaledDebtBalance;
            reserve.totalBorrowed -= position.borrowAmount;
            reserve.totalCollateral -= position.collateralAmount;
            
            position.scaledDebtBalance = 0;
            position.borrowAmount = 0;
            position.collateralAmount = 0;
        } else {
            // Partial liquidation - update position
            uint256 newScaledDebt = Core.calculateNewScaledDebt(
                position.scaledDebtBalance,
                actualDebtCovered,
                reserve.variableBorrowIndex
            );
            
            uint256 borrowReduction = position.borrowAmount.percentMul(
                actualDebtCovered.percentDiv(userTotalDebt)
            );
            
            reserve.totalScaledBorrowed = reserve.totalScaledBorrowed - position.scaledDebtBalance + newScaledDebt;
            reserve.totalBorrowed -= borrowReduction;
            reserve.totalCollateral -= collateralLiquidated;
            
            position.scaledDebtBalance = newScaledDebt;
            position.borrowAmount -= borrowReduction;
            position.collateralAmount -= collateralLiquidated;
        }

        // Transfer collateral to liquidator or convert to supply asset
        if (receiveCollateral) {
            IERC20(predictionAsset).safeTransfer(liquidator, collateralLiquidated);
        } else {
            // revert PolynanceEE.NotImplemented();
        }

        return (actualDebtCovered, collateralLiquidated);
    }

    // ============ Public Interface Functions ============

    /**
     * @notice Liquidate an undercollateralized position
     * @param user The address of the user to liquidate
     * @param debtToCover The amount of debt to repay
     * @param predictionAsset The prediction token used as collateral
     * @param receiveCollateral True to receive collateral, false to receive supply asset
     */
    function liquidate(
        address liquidator,
        address user,
        uint256 debtToCover,
        address predictionAsset,
        bool receiveCollateral
    ) internal returns (uint256 actualDebtCovered, uint256 collateralLiquidated) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(predictionAsset, rp.supplyAsset);
        Storage.UserPosition storage position = Core.getUserPosition(marketId, user);

        // Basic validation
        if (!rp.isActive) revert PolynanceEE.MarketNotActive();
        if (debtToCover == 0) revert PolynanceEE.InvalidAmount();
        if (position.scaledDebtBalance == 0) revert PolynanceEE.NoDebtToRepay();
        // if (liquidator == user) revert PolynanceEE.CannotLiquidateSelf();

        // Update indices
        _updateIndices(predictionAsset);

        // Check if position is liquidatable
        uint256 healthFactor = _calculateHealthFactor(user, predictionAsset);
        if (!Core.isLiquidatable(healthFactor)) {
            revert PolynanceEE.PositionHealthy();
        }

        // Execute liquidation
        (actualDebtCovered, collateralLiquidated) = _executeLiquidation(
            liquidator,
            user,
            debtToCover,
            predictionAsset,
            receiveCollateral
        );

        emit LiquidationCall(
            predictionAsset,
            rp.supplyAsset,
            user,
            actualDebtCovered,
            collateralLiquidated,
            liquidator,
            receiveCollateral
        );

        return (actualDebtCovered, collateralLiquidated);
    }

    /**
     * @notice Get user's current health factor
     * @param user Address of the user
     * @param predictionAsset The prediction token used as collateral
     * @return healthFactor The user's health factor (1e27 = 1.0)
     */
    function getUserHealthFactor(address user, address predictionAsset) internal view returns (uint256 healthFactor) {
        return _calculateHealthFactor(user, predictionAsset);
    }

    /**
     * @notice Check if a position is liquidatable
     * @param user Address of the user
     * @param predictionAsset The prediction token used as collateral
     * @return True if the position can be liquidated
     */
    function isUserLiquidatable(address user, address predictionAsset) internal view returns (bool) {
        uint256 healthFactor = _calculateHealthFactor(user, predictionAsset);
        return Core.isLiquidatable(healthFactor);
    }
}