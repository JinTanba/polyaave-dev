// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/protocol/libraries/math/PercentageMath.sol";
import {MathUtils} from "@aave/protocol/libraries/math/MathUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title CoreMath
 * @notice Pure mathematical library for all PolynanceLend V2 calculations
 * @dev Contains only pure functions - no state access
 */
library CoreMath {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using Math for uint256;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant RAY = 1e27;
    
    // Export constants for use in other contracts
    function ray() internal pure returns (uint256) { return RAY; }
    function maxBps() internal pure returns (uint256) { return MAX_BPS; }

    // ============ Interest Rate Calculations ============

    /**
     * @notice Calculate utilization rate
     * @param totalBorrowed Total borrowed amount
     * @param totalSupplied Total supplied amount
     * @return utilization Utilization rate in Ray
     */
    function calculateUtilization(
        uint256 totalBorrowed,
        uint256 totalSupplied
    ) internal pure returns (uint256 utilization) {
        if (totalSupplied == 0) return 0;
        return totalBorrowed.rayDiv(totalSupplied);
    }

    /**
     * @notice Calculate spread rate based on utilization
     * @param totalBorrowed Total borrowed amount
     * @param totalSupplied Total supplied amount
     * @param baseSpreadRate Base spread rate in Ray
     * @param optimalUtilization Optimal utilization in Ray
     * @param slope1 Slope below optimal
     * @param slope2 Slope above optimal
     * @return spreadRate Spread rate in Ray
     */
    function calculateSpreadRate(
        uint256 totalBorrowed,
        uint256 totalSupplied,
        uint256 baseSpreadRate,
        uint256 optimalUtilization,
        uint256 slope1,
        uint256 slope2
    ) internal pure returns (uint256 spreadRate) {
        uint256 utilization = calculateUtilization(totalBorrowed, totalSupplied);
        
        if (utilization <= optimalUtilization) {
            spreadRate = baseSpreadRate + slope1.rayMul(utilization);
        } else {
            uint256 excessUtilization = utilization - optimalUtilization;
            spreadRate = baseSpreadRate + 
                slope1.rayMul(optimalUtilization) +
                slope2.rayMul(excessUtilization);
        }
        
        return spreadRate;
    }

    /**
     * @notice Calculate new borrow index after time elapsed
     * @param currentIndex Current borrow index
     * @param spreadRate Current spread rate
     * @param lastUpdateTimestamp Last update timestamp
     * @return newIndex New borrow index
     */
    function calculateNewBorrowIndex(
        uint256 currentIndex,
        uint256 spreadRate,
        uint256 lastUpdateTimestamp
    ) internal view returns (uint256 newIndex) {
        
        uint256 compoundedInterest = MathUtils.calculateCompoundedInterest(
            spreadRate,
            uint40(lastUpdateTimestamp),
            block.timestamp
        );
        
        return currentIndex.rayMul(compoundedInterest);
    }

    // ============ Debt Calculations ============

    /**
     * @notice Calculate user's current total debt using debt ratio
     * @param userBorrowAmount User's initial borrow amount
     * @param marketTotalBorrowed Market's total initial borrowed
     * @param userPrincipalDebt User's principal debt from liquidity layer (calculated externally)
     * @param userScaledPolynanceDebt User's scaled debt for spread calculation
     * @param polynanceBorrowIndex Current Polynance borrow index
     * @return totalDebt Total debt (liquidity layer principal + interest + Polynance spread)
     * @return principalDebt Principal debt including liquidity layer interest
     * @return spreadDebt Polynance spread only
     */
    function calculateUserTotalDebt(
        uint256 userBorrowAmount,
        uint256 marketTotalBorrowed,
        uint256 userPrincipalDebt,
        uint256 userScaledPolynanceDebt,
        uint256 polynanceBorrowIndex
    ) internal pure returns (
        uint256 totalDebt,
        uint256 principalDebt,
        uint256 spreadDebt
    ) {
        // Principal debt is provided (includes liquidity layer interest)
        principalDebt = userPrincipalDebt;
        
        // Calculate Polynance spread
        uint256 polynanceDebtWithSpread = userScaledPolynanceDebt.rayMul(polynanceBorrowIndex);
        spreadDebt = polynanceDebtWithSpread > userBorrowAmount ? 
            polynanceDebtWithSpread - userBorrowAmount : 0;
        
        // Total debt
        totalDebt = principalDebt + spreadDebt;
        
        return (totalDebt, principalDebt, spreadDebt);
    }

    /**
     * @notice Calculate scaled debt amount for Polynance spread tracking
     * @param borrowAmount Amount being borrowed
     * @param polynanceBorrowIndex Current Polynance borrow index
     * @return scaledPolynanceDebt Scaled debt for Polynance spread tracking
     */
    function calculateScaledDebt(
        uint256 borrowAmount,
        uint256 polynanceBorrowIndex
    ) internal pure returns (uint256 scaledPolynanceDebt) {
        return borrowAmount.rayDiv(polynanceBorrowIndex);
    }

    /**
     * @notice Calculate scaled repayment for Polynance spread reduction
     * @param spreadRepayment Amount of spread being repaid
     * @param polynanceBorrowIndex Current Polynance borrow index
     * @return scaledRepayment Scaled amount to reduce from user's balance
     */
    function calculateScaledRepayment(
        uint256 spreadRepayment,
        uint256 polynanceBorrowIndex
    ) internal pure returns (uint256 scaledRepayment) {
        return spreadRepayment.rayDiv(polynanceBorrowIndex);
    }

    // ============ Collateral & Borrowing Calculations ============

    /**
     * @notice Calculate collateral value in supply asset terms
     * @param collateralAmount Amount of collateral
     * @param collateralPrice Price in Ray
     * @param supplyDecimals Supply asset decimals
     * @param collateralDecimals Collateral asset decimals
     * @return value Collateral value in supply asset
     */
    function calculateCollateralValue(
        uint256 collateralAmount,
        uint256 collateralPrice,
        uint256 supplyDecimals,
        uint256 collateralDecimals
    ) internal pure returns (uint256 value) {
        return collateralAmount
            .mulDiv(collateralPrice, RAY)
            .mulDiv(10**supplyDecimals, 10**collateralDecimals);
    }

    /**
     * @notice Calculate maximum borrow amount
     * @param collateralValue Collateral value in supply asset
     * @param ltv Loan-to-value ratio in basis points
     * @return maxBorrow Maximum borrow amount
     */
    function calculateMaxBorrow(
        uint256 collateralValue,
        uint256 ltv
    ) internal pure returns (uint256 maxBorrow) {
        return collateralValue.percentMul(ltv);
    }

    /**
     * @notice Calculate health factor
     * @param collateralValue Collateral value in supply asset
     * @param totalDebt Total debt amount
     * @param liquidationThreshold Liquidation threshold in basis points
     * @return healthFactor Health factor in Ray
     */
    function calculateHealthFactor(
        uint256 collateralValue,
        uint256 totalDebt,
        uint256 liquidationThreshold
    ) internal pure returns (uint256 healthFactor) {
        if (totalDebt == 0) return type(uint256).max;
        
        uint256 adjustedCollateralValue = collateralValue.percentMul(liquidationThreshold);
        return adjustedCollateralValue.rayDiv(totalDebt);
    }

    // ============ Liquidation Calculations ============
    /**
     * @notice Calculate maximum liquidatable debt
     * @param totalDebt Total debt amount
     * @param liquidationCloseFactor Close factor in basis points
     * @return maxLiquidatable Maximum debt that can be liquidated
     */
    function calculateMaxLiquidatable(
        uint256 totalDebt,
        uint256 liquidationCloseFactor
    ) internal pure returns (uint256 maxLiquidatable) {
        return totalDebt.percentMul(liquidationCloseFactor);
    }

    // ============ Supply Side Calculations (V2 Simplified) ============

    /**
     * @notice Calculate LP tokens to mint (V2: always 1:1)
     * @param supplyAmount Amount being supplied
     * @return lpTokensToMint LP tokens to mint
     */
    function calculateLPTokensToMint(
        uint256 supplyAmount
    ) internal pure returns (uint256 lpTokensToMint) {
        // V2: Simple 1:1 minting
        return supplyAmount;
    }

    /**
     * @notice Calculate spread earned
     * @param totalScaledBorrowed Total scaled borrowed
     * @param borrowIndex Current borrow index
     * @param totalBorrowed Total borrowed principal
     * @return spreadEarned Total spread earned
     */
    function calculateSpreadEarned(
        uint256 totalScaledBorrowed,
        uint256 borrowIndex,
        uint256 totalBorrowed
    ) internal pure returns (uint256 spreadEarned) {
        uint256 currentTotalDebt = totalScaledBorrowed.rayMul(borrowIndex);
        return currentTotalDebt > totalBorrowed ? currentTotalDebt - totalBorrowed : 0;
    }

    // ============ Resolution Calculations ============

    /**
     * @notice Calculate spread distribution
     * @param totalSpread Total spread earned
     * @param reserveFactor Reserve factor in basis points
     * @return protocolShare Protocol's share of spread
     * @return lpShare LPs' share of spread
     */
    function distributeSpread(
        uint256 totalSpread,
        uint256 reserveFactor
    ) internal pure returns (
        uint256 protocolShare,
        uint256 lpShare
    ) {
        protocolShare = totalSpread.percentMul(reserveFactor);
        lpShare = totalSpread - protocolShare;
        return (protocolShare, lpShare);
    }

    /**
     * @notice Calculate three-pool distribution at resolution
     * @param totalRedeemed Total collateral redeemed
     * @param liquidityDebt Debt owed to liquidity layer
     * @param protocolSpread Protocol's spread share
     * @param lpSpread LPs' spread share
     * @param lpShareOfExcess LP share of excess in basis points
     * @return liquidityRepayment Amount to repay liquidity layer
     * @return protocolPool Protocol's total allocation
     * @return lpPool LPs' total allocation
     * @return borrowerPool Borrowers' rebate allocation
     */
    function calculateResolutionPools(
        uint256 totalRedeemed,
        uint256 liquidityDebt,
        uint256 protocolSpread,
        uint256 lpSpread,
        uint256 lpShareOfExcess
    ) internal pure returns (
        uint256 liquidityRepayment,
        uint256 protocolPool,
        uint256 lpPool,
        uint256 borrowerPool
    ) {
        // First, repay liquidity layer
        liquidityRepayment = totalRedeemed >= liquidityDebt ? liquidityDebt : totalRedeemed;
        uint256 remaining = totalRedeemed - liquidityRepayment;
        
        // Then, pay spread obligations
        if (remaining >= protocolSpread + lpSpread) {
            // Can pay all spread
            protocolPool = protocolSpread;
            lpPool = lpSpread;
            
            // Distribute excess
            uint256 excess = remaining - protocolPool - lpPool;
            uint256 lpExcessShare = excess.percentMul(lpShareOfExcess);
            lpPool += lpExcessShare;
            borrowerPool = excess - lpExcessShare;
        } else if (remaining >= protocolSpread) {
            // Can pay protocol fully, LP partially
            protocolPool = protocolSpread;
            lpPool = remaining - protocolPool;
            borrowerPool = 0;
        } else {
            // Can only pay protocol partially
            protocolPool = remaining;
            lpPool = 0;
            borrowerPool = 0;
        }
        
        return (liquidityRepayment, protocolPool, lpPool, borrowerPool);
    }

    /**
     * @notice Calculate LP token value at resolution
     * @param lpPoolAllocation Total LP pool allocation
     * @param liquidityBalance Liquidity layer balance (principal + interest)
     * @param totalLPTokens Total LP tokens outstanding
     * @param totalSupplied Original total supplied
     * @return tokenValue Value per LP token in Ray
     * @return principalLoss Any principal loss amount
     */
    function calculateLPTokenValue(
        uint256 lpPoolAllocation,
        uint256 liquidityBalance,
        uint256 totalLPTokens,
        uint256 totalSupplied
    ) internal pure returns (
        uint256 tokenValue,
        uint256 principalLoss
    ) {
        if (totalLPTokens == 0) return (0, 0);
        
        uint256 totalLPValue = liquidityBalance + lpPoolAllocation;
        
        // Check for principal loss
        if (totalLPValue < totalSupplied) {
            principalLoss = totalSupplied - totalLPValue;
        }
        
        // Calculate token value
        tokenValue = totalLPValue.rayDiv(totalLPTokens);
        
        return (tokenValue, principalLoss);
    }

    /**
     * @notice Calculate individual LP claim
     * @param lpTokenBalance User's LP token balance
     * @param lpTokenValue Value per LP token in Ray
     * @return claimAmount Amount user can claim
     */
    function calculateLPClaim(
        uint256 lpTokenBalance,
        uint256 lpTokenValue
    ) internal pure returns (uint256 claimAmount) {
        return lpTokenBalance.rayMul(lpTokenValue);
    }

    /**
     * @notice Calculate borrower's rebate share
     * @param userCollateral User's collateral amount
     * @param totalCollateral Total collateral in market
     * @param borrowerPool Total borrower rebate pool
     * @return rebateAmount User's rebate amount
     */
    function calculateBorrowerRebate(
        uint256 userCollateral,
        uint256 totalCollateral,
        uint256 borrowerPool
    ) internal pure returns (uint256 rebateAmount) {
        if (totalCollateral == 0) return 0;
        return borrowerPool.mulDiv(userCollateral, totalCollateral);
    }
}
