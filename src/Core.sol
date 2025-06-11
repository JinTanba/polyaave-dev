// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/protocol/libraries/math/PercentageMath.sol";
import {MathUtils} from "@aave/protocol/libraries/math/MathUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import { Storage as PolynanceStorage } from "./libraries/Storage.sol";
import "forge-std/console.sol";

library Core {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using Math for uint256;

    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant RAY = 1e27;

    // ============ Storage Access Functions ============
    
    function f() external pure returns (PolynanceStorage.$ storage l) {
        return PolynanceStorage.f();
    }

    function getMarketId(address asset, address collateralAsset) external pure returns (bytes32 marketId) {
        marketId = keccak256(abi.encodePacked(asset, collateralAsset));
    }

    function getReserveData(bytes32 marketId) external view returns (PolynanceStorage.ReserveData storage reserve) {
        return PolynanceStorage.f().markets[marketId];
    }

    function getPositionId(bytes32 marketId, address user) external pure returns (bytes32 positionId) {
        positionId = keccak256(abi.encodePacked(marketId, user));
    }

    function getUserPosition(bytes32 marketId, address user) external view returns (PolynanceStorage.UserPosition storage position) {
        return PolynanceStorage.f().positions[keccak256(abi.encodePacked(marketId, user))];
    }

    function getResolutionData(bytes32 marketId) external view returns(PolynanceStorage.ResolutionData storage) {
        return PolynanceStorage.f().resolutions[marketId];
    }


    struct CalcPureSpreadRateInput {
        uint256 totalBorrowedPrincipal;
        uint256 totalPolynanceSupply;
        PolynanceStorage.RiskParams riskParams;
    }

    struct UpdateIndicesInput {
        PolynanceStorage.ReserveData reserve;
        PolynanceStorage.RiskParams riskParams;
    }

    struct CalcUserTotalDebtInput {
        uint256 principalDebt;    //Debt with aave borrow interest(Aavemodule.)
        uint256 scaledPolynanceSpreadDebtPrincipal; //borrowAmount * borrowIndex
        uint256 initialBorrowAmount;
        uint256 currentPolynanceSpreadBorrowIndex;
    }

    struct CalcScaledPrincipalsInput {
        uint256 borrowAmount;
        uint256 currentPolynanceSpreadBorrowIndex;
    }

    struct CalcMaxBorrowInput {
        uint256 collateralAmount;
        uint256 collateralPrice;
        uint256 ltv;
        uint256 supplyAssetDecimals;
        uint256 collateralAssetDecimals;
    }

    
    struct CalcSupplyRateInput {
        uint256 totalBorrowedPrincipal;
        uint256 totalPolynanceSupply;
        PolynanceStorage.RiskParams riskParams;
    }

    struct CalcSupplyInput {
        uint256 supplyAmount;
        uint256 currentLiquidityIndex;
    }

    struct CalcWithdrawInput {
        uint256 lpTokenAmount;
        uint256 totalLPTokenSupply;
        uint256 totalAvailableLiquidity;
        uint256 currentLiquidityIndex;
    }


    function calculateUtilization(
        uint256 totalBorrowedPrincipal,
        uint256 totalPolynanceSupply
    ) public pure returns (uint256) {
        if (totalPolynanceSupply == 0) return 0;
        return totalBorrowedPrincipal.rayDiv(totalPolynanceSupply);
    }

    struct MarketResolveOutputs {
        // $P_{A,PoolRepayment}$: Total amount of supplyAsset the pool should attempt to repay to Aave.
        uint256 amountToRepayAave;

        // $L_{LP,Principal}$: Total principal loss to be socialized across LPs.
        // This occurs if valueOfCollateralRedeemed < poolOriginalPrincipalBorrowedFromAave.
        uint256 socializedLpPrincipalLoss;

        // $A_{S,Proto}$: Protocol's revenue share from the collected Polynance spread.
        uint256 protocolSpreadRevenue;

        // $A_{S,LP}$: LPs' collective share from the collected Polynance spread (for pro-rata claims).
        uint256 lpSpreadShareAllocation;

        // $B_{LP,Excess}$: LPs' collective bonus from true excess collateral (for pro-rata claims).
        uint256 lpExcessBonusAllocation;

        // $R_{B,Excess}$: Borrowers' collective rebate from true excess collateral (for pro-rata claims).
        uint256 borrowerRebateAllocation;
    }

    function calculateSpreadRate(
        CalcPureSpreadRateInput memory input
    ) public pure returns (uint256 spreadRateRay) {
        uint256 utilization = calculateUtilization(
            input.totalBorrowedPrincipal,
            input.totalPolynanceSupply
        );

        if (utilization <= input.riskParams.optimalUtilization) {
            spreadRateRay = input.riskParams.baseSpreadRate +
                input.riskParams.slope1.rayMul(utilization);
        } else {
            //if utilization is greater than optimal utilization, use the slope2
            uint256 excessUtilization = utilization - input.riskParams.optimalUtilization;
            spreadRateRay = input.riskParams.baseSpreadRate +
                input.riskParams.slope1.rayMul(input.riskParams.optimalUtilization) +
                input.riskParams.slope2.rayMul(excessUtilization);
        }
        return spreadRateRay;
    }
    
    function calculateSupplyRate(
        CalcSupplyRateInput memory input
    ) public pure returns (uint256) {
        uint256 utilization = calculateUtilization(
            input.totalBorrowedPrincipal,
            input.totalPolynanceSupply
        );
        uint256 pureSpreadRate = calculateSpreadRate(
            CalcPureSpreadRateInput({
                totalBorrowedPrincipal: input.totalBorrowedPrincipal,
                totalPolynanceSupply: input.totalPolynanceSupply,
                riskParams: input.riskParams
            })
        );

        uint256 supplyRate = pureSpreadRate.rayMul(utilization);
        return supplyRate;
    }

    function updateIndices(
        UpdateIndicesInput memory input
    ) external view returns (
        uint256 newPolynanceSpreadBorrowIndex,
        uint256 newliquidityIndex
    ) {
        uint256 timeDelta = block.timestamp - input.reserve.lastUpdateTimestamp;
        PolynanceStorage.ReserveData memory reserve = input.reserve;

        if(reserve.lastUpdateTimestamp == 0) {
            console.log("INITIALIZE INDICES");
            return (WadRayMath.RAY, WadRayMath.RAY);
        }

        uint256 currentTotalSupplyPrincipal = reserve.totalScaledSupplied.rayMul(reserve.liquidityIndex);
        uint256 currentTotalBorrowedPrincipal = reserve.totalScaledBorrowed.rayMul(reserve.variableBorrowIndex);

        CalcPureSpreadRateInput memory pureSpreadRateInput = CalcPureSpreadRateInput({
            totalBorrowedPrincipal: currentTotalBorrowedPrincipal,
            totalPolynanceSupply: currentTotalSupplyPrincipal,
            riskParams: input.riskParams
        });
        uint256 pureSpreadRateRay = calculateSpreadRate(pureSpreadRateInput);

        CalcSupplyRateInput memory lpRateInput = CalcSupplyRateInput({
            totalBorrowedPrincipal: currentTotalBorrowedPrincipal,
            totalPolynanceSupply: currentTotalSupplyPrincipal,
            riskParams: input.riskParams
        });
        uint256 lpSupplyRateFromSpreadRay = calculateSupplyRate(lpRateInput);
        
        newPolynanceSpreadBorrowIndex = MathUtils.calculateCompoundedInterest(
            pureSpreadRateRay,
            uint40(reserve.lastUpdateTimestamp)
        ).rayMul(reserve.variableBorrowIndex);

        newliquidityIndex = MathUtils.calculateCompoundedInterest(
            lpSupplyRateFromSpreadRay,
            uint40(reserve.lastUpdateTimestamp)
        ).rayMul(reserve.liquidityIndex);


        return (newPolynanceSpreadBorrowIndex, newliquidityIndex);
    }

    function calculateUserTotalDebt(
        CalcUserTotalDebtInput memory input
    ) external pure returns (uint256 totalDebt, uint256 principalDebt, uint256 pureSpreadInterest) {
        uint256 totalValueAccruedFromSpread = input.scaledPolynanceSpreadDebtPrincipal.rayMul(input.currentPolynanceSpreadBorrowIndex);
        pureSpreadInterest = totalValueAccruedFromSpread > input.initialBorrowAmount ? totalValueAccruedFromSpread - input.initialBorrowAmount : 0;
        totalDebt = input.principalDebt + pureSpreadInterest;
        return (totalDebt, input.principalDebt, pureSpreadInterest);
    }

    function calculateScaledPrincipals(
        CalcScaledPrincipalsInput memory input
    ) external pure returns (uint256 scaledSpreadPrincipal) {
        scaledSpreadPrincipal = input.borrowAmount.rayDiv(input.currentPolynanceSpreadBorrowIndex);
        return (scaledSpreadPrincipal);
    }

    function calculateScaledValue(uint256 amount, uint256 index) external pure returns (uint256) {
        return amount.rayDiv(index);
    }
    
    function calculateBorrowAble(
        CalcMaxBorrowInput memory input
    ) external pure returns (uint256) {
        uint256 collateralValueInSupplyAsset = input.collateralAmount
            .mulDiv(input.collateralPrice.wadToRay(), RAY) // price is Ray
            .mulDiv(10**input.supplyAssetDecimals, 10**input.collateralAssetDecimals);
        
        return collateralValueInSupplyAsset.percentMul(input.ltv);
    }

    function validateBorrow(
        uint256 newTotalBorrowed, // This should be total principal borrowed
        uint256 totalPolynanceSupply, // Total principal supplied by LPs to Polynance
        uint256 borrowAmount,
        uint256 maxBorrowForUser
    ) external pure returns (bool) {
        if (borrowAmount > maxBorrowForUser) return false;
        if (newTotalBorrowed > totalPolynanceSupply) return false; // Not enough principal in Polynance
        return true;
    }

    function calculateSupplyShares(
        CalcSupplyInput memory input
    ) external pure returns (uint256 lpTokensToMint) {
        lpTokensToMint = input.supplyAmount.rayDiv(input.currentLiquidityIndex);
        return lpTokensToMint;
    }

    function validateSupply(
        uint256 supplyAmount
    ) external pure returns (bool) {
        return supplyAmount > 0;
    }

    function validateWithdraw(
        uint256 lpTokenAmount,
        uint256 userLPTokenBalance,
        uint256 totalAvailableLiquidity
    ) external pure returns (bool) {
        if (lpTokenAmount == 0) return false;
        if (lpTokenAmount > userLPTokenBalance) return false;
        if (totalAvailableLiquidity == 0) return false;
        return true;
    }

    /**
     * @notice Calculate the scaled supply balance for a new position
     * @param supplyAmount Amount being supplied
     * @param currentLiquidityIndex Current liquidity index
     * @return scaledBalance The scaled balance to store
     */
    function calculateScaledSupplyBalance(
        uint256 supplyAmount,
        uint256 currentLiquidityIndex
    ) external pure returns (uint256 scaledBalance) {
        scaledBalance = supplyAmount.rayDiv(currentLiquidityIndex);
        return scaledBalance;
    }


    // ============ Market Resolution Pure Calculations ============

    struct CalcThreePoolDistributionInput {
        uint256 totalCollateralRedeemed;
        uint256 aaveCurrentTotalDebt;
        uint256 accumulatedSpread;
        uint256 currentBorrowIndex;
        uint256 totalScaledBorrowed;
        uint256 totalNotScaledBorrowed;
        uint256 reserveFactor;
        uint256 lpShareOfRedeemed;
    }

    struct ThreePoolDistributionResult {
        uint256 aaveDebtRepaid;
        uint256 lpSpreadPool;
        uint256 borrowerPool;
        uint256 protocolPool;
    }

    struct CalcLpClaimInput {
        uint256 scaledSupplyBalance;
        uint256 totalScaledSupplied;
        uint256 lpSpreadPool;
    }

    struct CalcBorrowerClaimInput {
        uint256 positionCollateralAmount;
        uint256 totalCollateral;
        uint256 borrowerPool;
    }

    function calculateThreePoolDistribution(
        CalcThreePoolDistributionInput memory input
    ) external pure returns (ThreePoolDistributionResult memory result) {
        // Step 1: Calculate total Polynance spread --- wrong
        //currentSpreadEarned=(scaled*index)-totalBorrowed
        uint256 currentSpreadEarned = input.totalScaledBorrowed.rayMul(input.currentBorrowIndex) - input.totalNotScaledBorrowed;
        uint256 totalPolynanceSpread = input.accumulatedSpread + currentSpreadEarned;
        
        // Step 2: Split spread between protocol and LPs
        uint256 protocolSpreadShare = totalPolynanceSpread.percentMul(input.reserveFactor);
        uint256 lpSpreadShare = totalPolynanceSpread - protocolSpreadShare;
        
        // Step 3: Repay Aave first
        result.aaveDebtRepaid = input.totalCollateralRedeemed >= input.aaveCurrentTotalDebt ?
            input.aaveCurrentTotalDebt : input.totalCollateralRedeemed;
        
        uint256 remainingFunds = input.totalCollateralRedeemed - result.aaveDebtRepaid;

        console.log("                                        totalCollateralRedeemed: ", input.totalCollateralRedeemed);
        console.log("                                        remainingFunds: ", remainingFunds, input.aaveCurrentTotalDebt);
        console.log("                                        protocolSpreadShare: ", protocolSpreadShare);
        console.log("                                        accumulatedSpread: ", lpSpreadShare);
        console.log("                                        +: ", protocolSpreadShare+ lpSpreadShare);
        console.log("                                        currentSpreadEarned: ", currentSpreadEarned);
        console.log("                                        totalPolynanceSpread: ", totalPolynanceSpread);

        
        // Step 4: Distribute remaining funds to three pools
        if (remainingFunds >= protocolSpreadShare + lpSpreadShare) {
            console.log("                                        BEST CASE: Can pay all spread obligations and excess");
            // Can pay all spread obligations
            result.protocolPool = protocolSpreadShare;
            result.lpSpreadPool = lpSpreadShare;
            
            // Distribute excess
            uint256 excess = remainingFunds - result.protocolPool - result.lpSpreadPool;
            uint256 lpExcessShare = excess.percentMul(input.lpShareOfRedeemed);
            result.lpSpreadPool += lpExcessShare;
            result.borrowerPool = excess - lpExcessShare;
        } else if (remainingFunds >= protocolSpreadShare) {
            console.log("                                        PARTIAL CASE: Can pay protocol spread fully, LP partially");
            // Can pay protocol fully, LP partially
            result.protocolPool = protocolSpreadShare;
            result.lpSpreadPool = remainingFunds - result.protocolPool;
            result.borrowerPool = 0;
        } else {
            console.log("                                        Worst CASE: Can only pay protocol spread partially");
            // Can only pay protocol partially
            result.protocolPool = remainingFunds;
            result.lpSpreadPool = 0;
            result.borrowerPool = 0;
        }
        
        return result;
    }

    function calculateLpClaimAmount(
        CalcLpClaimInput memory input
    ) external pure returns (uint256 claimAmount) {
        if (input.totalScaledSupplied == 0) return 0;
        
        uint256 userShare = input.scaledSupplyBalance.percentDiv(input.totalScaledSupplied);
        claimAmount = input.lpSpreadPool.percentMul(userShare);
        
        return claimAmount;
    }

    function calculateBorrowerClaimAmount(
        CalcBorrowerClaimInput memory input
    ) external pure returns (uint256 claimAmount) {
        if (input.totalCollateral == 0) return 0;
        
        claimAmount = input.borrowerPool.mulDiv(
            input.positionCollateralAmount,
            input.totalCollateral
        );
        
        return claimAmount;
    }

    // ============ Liquidation Functions ============
    struct CalcLiquidationAmountsInput {
        uint256 userTotalDebt;              // Total debt (principal + spread)
        uint256 collateralAmount;           // User's collateral amount
        uint256 collateralPrice;            // Current collateral price (Ray)
        uint256 liquidationCloseFactor;     // Max % of debt liquidatable (basis points)
        uint256 liquidationBonus;           // Liquidator incentive (basis points)
        uint256 supplyAssetDecimals;
        uint256 collateralAssetDecimals;
    }

    struct CalcHealthFactorInput {
        uint256 collateralAmount;
        uint256 collateralPrice;
        uint256 userTotalDebt;
        uint256 liquidationThreshold;
        uint256 supplyAssetDecimals;
        uint256 collateralAssetDecimals;
    }

    struct LiquidationAmountsResult {
        uint256 debtToRepay;                // Amount liquidator must repay
        uint256 collateralToSeize;          // Collateral liquidator receives
        uint256 liquidationBonus;           // Bonus amount in collateral
        bool isFullLiquidation;             // Whether entire position is liquidated
    }

    struct ValidateLiquidationInput {
        uint256 healthFactor;               // Current health factor
        uint256 repayAmount;                // Amount liquidator wants to repay
        uint256 maxRepayAmount;             // Max allowed by close factor
        uint256 userTotalDebt;              // User's total debt
        uint256 availableCollateral;        // User's collateral
    }


    function calculateHealthFactor(
        CalcHealthFactorInput memory input
    ) external pure returns (uint256 healthFactor) {
        if (input.userTotalDebt == 0) {
            return type(uint256).max; // Infinite health factor if no debt
        }
        
        // Convert collateral value to supply asset terms
        uint256 collateralValueInSupplyAsset = input.collateralAmount
            .mulDiv(input.collateralPrice, RAY) // price is Ray
            .mulDiv(10**input.supplyAssetDecimals, 10**input.collateralAssetDecimals);
        
        uint256 adjustedCollateralValue = collateralValueInSupplyAsset
            .percentMul(input.liquidationThreshold);

        healthFactor = adjustedCollateralValue.rayDiv(input.userTotalDebt);
        
        return healthFactor;
    }

    function isLiquidatable(uint256 healthFactor) internal pure returns (bool) {
        return healthFactor < RAY; // Less than 1e27 means unhealthy
    }

    function calculateLiquidationAmounts(
        CalcLiquidationAmountsInput memory input
    ) external pure returns (LiquidationAmountsResult memory result) {
        // Calculate max debt that can be repaid based on close factor
        uint256 maxDebtRepayable = input.userTotalDebt
            .percentMul(input.liquidationCloseFactor);
        
        // Debt to repay is the full user debt if below max, otherwise capped
        result.debtToRepay = input.userTotalDebt <= maxDebtRepayable ? 
            input.userTotalDebt : maxDebtRepayable;
        
        // Check if this is a full liquidation
        result.isFullLiquidation = result.debtToRepay == input.userTotalDebt;
        
        // Calculate base collateral value equivalent to debt being repaid
        // First convert debt to collateral asset terms using price
        uint256 baseCollateralValue = result.debtToRepay
            .mulDiv(10**input.collateralAssetDecimals, 10**input.supplyAssetDecimals)
            .rayDiv(input.collateralPrice);
        
        // Apply liquidation bonus
        uint256 bonusMultiplier = MAX_BPS + input.liquidationBonus; // e.g., 10500 for 5% bonus
        result.collateralToSeize = baseCollateralValue
            .percentMul(bonusMultiplier);
        
        // Calculate the bonus amount separately for transparency
        result.liquidationBonus = result.collateralToSeize - baseCollateralValue;
        
        // Ensure we don't seize more than available collateral
        if (result.collateralToSeize > input.collateralAmount) {
            // Adjust to available collateral
            result.collateralToSeize = input.collateralAmount;
            
            // Recalculate debt that can be repaid with available collateral
            uint256 collateralValueInSupplyAsset = input.collateralAmount
                .mulDiv(input.collateralPrice, RAY)
                .mulDiv(10**input.supplyAssetDecimals, 10**input.collateralAssetDecimals);
            
            // Remove bonus to get actual repayable debt
            result.debtToRepay = collateralValueInSupplyAsset
                .percentDiv(bonusMultiplier);
            
            // This is now definitely a full liquidation
            result.isFullLiquidation = true;
            result.liquidationBonus = input.collateralAmount - baseCollateralValue;
        }
        
        return result;
    }

    function validateLiquidation(
        ValidateLiquidationInput memory input
    ) external pure returns (bool isValid, string memory reason) {
        // Check if position is unhealthy
        if (!isLiquidatable(input.healthFactor)) {
            return (false, "Position is healthy");
        }
        
        // Check if repay amount is positive
        if (input.repayAmount == 0) {
            return (false, "Repay amount must be positive");
        }
        
        // Check if repay amount exceeds max allowed by close factor
        if (input.repayAmount > input.maxRepayAmount) {
            return (false, "Repay amount exceeds close factor limit");
        }
        
        // Check if repay amount exceeds user's total debt
        if (input.repayAmount > input.userTotalDebt) {
            return (false, "Repay amount exceeds user debt");
        }
        
        // Check if user has collateral to seize
        if (input.availableCollateral == 0) {
            return (false, "No collateral to liquidate");
        }
        
        return (true, "");
    }

    // Helper function to calculate updated scaled debt after partial liquidation
    function calculateNewScaledDebt(
        uint256 currentScaledDebt,
        uint256 debtRepaid,
        uint256 currentBorrowIndex
    ) external pure returns (uint256 newScaledDebt) {
        // Calculate current total debt
        uint256 currentTotalDebt = currentScaledDebt.rayMul(currentBorrowIndex);
        
        // Subtract repaid amount
        uint256 remainingDebt = currentTotalDebt > debtRepaid ? 
            currentTotalDebt - debtRepaid : 0;
        
        // Convert back to scaled amount
        newScaledDebt = remainingDebt.rayDiv(currentBorrowIndex);
        
        return newScaledDebt;
    }
}