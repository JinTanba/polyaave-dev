// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/protocol/libraries/math/PercentageMath.sol";
import {MathUtils} from "@aave/protocol/libraries/math/MathUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import { Storage as PolynanceStorage } from "./libraries/Storage.sol";

library Core {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using Math for uint256;

    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant RAY = 1e27;

    // ============ Storage Access Functions ============
    
    function f() internal pure returns (PolynanceStorage.$ storage l) {
        return PolynanceStorage.f();
    }

    function getMarketId(address asset, address collateralAsset) internal pure returns (bytes32 marketId) {
        marketId = keccak256(abi.encodePacked(asset, collateralAsset));
    }

    function getReserveData(bytes32 marketId) internal view returns (PolynanceStorage.ReserveData storage reserve) {
        return f().markets[marketId];
    }

    function getPositionId(bytes32 marketId, address user) internal pure returns (bytes32 positionId) {
        positionId = keccak256(abi.encodePacked(marketId, user));
    }

    function getUserPosition(bytes32 marketId, address user) internal view returns (PolynanceStorage.UserPosition storage position) {
        return f().positions[getPositionId(marketId, user)];
    }

    function getResolutionData(bytes32 marketId) internal view returns(PolynanceStorage.ResolutionData storage) {
        return f().resolutions[marketId];
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

    struct CalcHealthFactorInput {
        uint256 collateralAmount;
        uint256 collateralPrice;
        uint256 userTotalDebt;
        uint256 liquidationThreshold;
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

    struct CalcSupplyPositionValueInput {
        PolynanceStorage.SupplyPosition position;
        uint256 currentLiquidityIndex;
        uint256 principalWithdrawAmount;  // Current balance from Aave (includes Aave interest)
    }

    struct HealthFactorParams {
        uint256 collateralAmount;
        uint256 collateralPrice;
        uint256 collateralLiquidationThreshold;
        uint256 debtAmount;
        uint256 debtPrice;
    }

    struct LiquidationQuoteParams {
        // Debt details to calculate total debt and amount to cover
        uint256 debtAmount;
        uint256 debtPrice;
        // Collateral price to calculate how much collateral to disburse
        uint256 collateralPrice;
        // Protocol parameters
        uint256 liquidationBonus;
        uint256 closeFactor;
    }

    struct LiquidationQuote {
        uint256 debtToCover;
        uint256 collateralToReceive;
    }

    /**
     * @notice Normalize an amount from asset decimals to WAD (1e18)
     * @param amount The amount in asset decimals
     * @param decimals The number of decimals for the asset
     * @return The normalized amount in WAD
     */
    function normalizeToWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals > 18) {
            return amount / (10**(decimals - 18));
        } else {
            return amount * (10**(18 - decimals));
        }
    }

    /**
     * @notice Denormalize an amount from WAD (1e18) to asset decimals
     * @param amount The amount in WAD
     * @param decimals The target number of decimals
     * @return The denormalized amount in asset decimals
     */
    function denormalizeFromWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals > 18) {
            return amount * (10**(decimals - 18));
        } else {
            return amount / (10**(18 - decimals));
        }
    }

    function calculateUtilization(
        uint256 totalBorrowedPrincipal,
        uint256 totalPolynanceSupply
    ) internal pure returns (uint256) {
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
    ) internal pure returns (uint256 spreadRateRay) {
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
    ) internal pure returns (uint256) {
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
    ) internal view returns (
        uint256 newPolynanceSpreadBorrowIndex,
        uint256 newliquidityIndex
    ) {
        uint256 timeDelta = block.timestamp - input.reserve.lastUpdateTimestamp;
        PolynanceStorage.ReserveData memory reserve = input.reserve;

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
    ) internal pure returns (uint256 totalDebt, uint256 principalDebt, uint256 pureSpreadInterest) {
        uint256 totalValueAccruedFromSpread = input.scaledPolynanceSpreadDebtPrincipal.rayMul(input.currentPolynanceSpreadBorrowIndex);
        pureSpreadInterest = totalValueAccruedFromSpread > input.initialBorrowAmount ? totalValueAccruedFromSpread - input.initialBorrowAmount : 0;
        totalDebt = input.principalDebt + pureSpreadInterest;
        return (totalDebt, input.principalDebt, pureSpreadInterest);
    }

    function calculateScaledPrincipals(
        CalcScaledPrincipalsInput memory input
    ) internal pure returns (uint256 scaledSpreadPrincipal) {
        scaledSpreadPrincipal = input.borrowAmount.rayDiv(input.currentPolynanceSpreadBorrowIndex);
        return (scaledSpreadPrincipal);
    }

    function calculateScaledValue(uint256 amount, uint256 index) internal pure returns (uint256) {
        return amount.rayDiv(index);
    }
    
    function calculateBorrowAble(
        CalcMaxBorrowInput memory input
    ) internal pure returns (uint256) {
        uint256 collateralValueInSupplyAsset = input.collateralAmount
            .mulDiv(input.collateralPrice, RAY) // price is Ray
            .mulDiv(10**input.supplyAssetDecimals, 10**input.collateralAssetDecimals);
        
        return collateralValueInSupplyAsset.percentMul(input.ltv);
    }

    function calculateHealthFactor(
        CalcHealthFactorInput memory input
    ) internal pure returns (uint256) {
        if (input.userTotalDebt == 0) return type(uint256).max;
        if (input.collateralAmount == 0) return 0; // No collateral, HF is 0

        uint256 collateralValueInSupplyAsset = input.collateralAmount
            .mulDiv(input.collateralPrice, RAY) // price is Ray
            .mulDiv(10**input.supplyAssetDecimals, 10**input.collateralAssetDecimals);
        
        uint256 adjustedCollateralValue = collateralValueInSupplyAsset
            .percentMul(input.liquidationThreshold);

        if (adjustedCollateralValue == 0) return 0; // No effective collateral value after threshold, HF is 0

        // Check for potential overflow before rayDiv
        // if adjustedCollateralValue * RAY would overflow, and debt is non-zero, HF is effectively infinite
        if (adjustedCollateralValue >= type(uint256).max / RAY) {
            return type(uint256).max;
        }
        
        return adjustedCollateralValue.rayDiv(input.userTotalDebt);
    }

    function isPositionHealthy(uint256 healthFactor) internal pure returns (bool) {
        return healthFactor >= RAY;
    }

    function validateBorrow(
        uint256 newTotalBorrowed, // This should be total principal borrowed
        uint256 totalPolynanceSupply, // Total principal supplied by LPs to Polynance
        uint256 borrowAmount,
        uint256 maxBorrowForUser
    ) internal pure returns (bool) {
        if (borrowAmount > maxBorrowForUser) return false;
        if (newTotalBorrowed > totalPolynanceSupply) return false; // Not enough principal in Polynance
        return true;
    }

    function calculateSupplyShares(
        CalcSupplyInput memory input
    ) internal pure returns (uint256 lpTokensToMint) {
        lpTokensToMint = input.supplyAmount.rayDiv(input.currentLiquidityIndex);
        return lpTokensToMint;
    }

    function validateSupply(
        uint256 supplyAmount
    ) internal pure returns (bool) {
        return supplyAmount > 0;
    }

    function validateWithdraw(
        uint256 lpTokenAmount,
        uint256 userLPTokenBalance,
        uint256 totalAvailableLiquidity
    ) internal pure returns (bool) {
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
    ) internal pure returns (uint256 scaledBalance) {
        scaledBalance = supplyAmount.rayDiv(currentLiquidityIndex);
        return scaledBalance;
    }
    
    /**
     * @notice Calculate the total withdrawable amount for a supply position
     * @dev This calculates the total amount the LP should receive: principal + Aave interest + Polynance spread interest
     * @param input Input parameters for position value calculation
     * @return totalWithdrawable The total amount that can be withdrawn
     * @return aaveInterest Interest earned from Aave
     * @return polynanceInterest Interest earned from Polynance spread
     */
    function calculateSupplyPositionValue(
        CalcSupplyPositionValueInput memory input
    ) internal pure returns (
        uint256 totalWithdrawable,
        uint256 aaveInterest,
        uint256 polynanceInterest
    ) {
        // Calculate current value with Polynance interest
        uint256 polynanceValue = input.position.scaledSupplyBalance.rayMul(input.currentLiquidityIndex);
        
        // Calculate Aave interest (scaledSupplyBalancePrincipal includes principal + Aave interest)
        aaveInterest = input.principalWithdrawAmount > input.position.supplyAmount 
            ? input.principalWithdrawAmount - input.position.supplyAmount 
            : 0;
        
        // Calculate Polynance interest
        polynanceInterest = polynanceValue > input.position.supplyAmount 
            ? polynanceValue - input.position.supplyAmount 
            : 0;
        
        // Total withdrawable = principal + Aave interest + Polynance interest
        totalWithdrawable = input.position.supplyAmount + aaveInterest + polynanceInterest;
        
        return (totalWithdrawable, aaveInterest, polynanceInterest);
    }

        /**
     * @notice Calculates the health factor.
     * @param params A dedicated struct containing all necessary data for this calculation.
     * @return The health factor in WAD format.
     */
    function getHealthFactor(HealthFactorParams memory params)
        internal
        pure
        returns (uint256)
    {
        uint256 totalDebtBase = params.debtAmount.wadMul(params.debtPrice);
        if (totalDebtBase == 0) {
            return type(uint256).max;
        }

        uint256 collateralValueBase = params.collateralAmount.wadMul(
            params.collateralPrice
        );
        uint256 effectiveCollateralBase = collateralValueBase.percentMul(
            params.collateralLiquidationThreshold
        );

        return effectiveCollateralBase.wadDiv(totalDebtBase);
    }

    /**
     * @notice Checks if a position is liquidatable based on its parameters.
     * @param params The same struct used for getHealthFactor.
     * @return true if the position can be liquidated, false otherwise.
     */
    function isLiquidatable(HealthFactorParams memory params)
        internal
        pure
        returns (bool)
    {
        return getHealthFactor(params) <= WadRayMath.WAD;
    }

    /**
     * @notice Calculates the liquidation quote.
     * @param params A dedicated struct containing all necessary data for this calculation.
     * @return A struct with the calculated `debtToCover` and `collateralToReceive` amounts.
     */
    function getLiquidationQuote(LiquidationQuoteParams memory params)
        internal
        pure
        returns (LiquidationQuote memory)
    {
        uint256 totalDebtBase = params.debtAmount.wadMul(params.debtPrice);
        if (totalDebtBase == 0) {
            return LiquidationQuote(0, 0);
        }

        uint256 debtToCoverBase = totalDebtBase.percentMul(params.closeFactor);

        uint256 collateralToSeizeBase = debtToCoverBase.percentMul(
            MAX_BPS + params.liquidationBonus
        );

        uint256 debtAmount = debtToCoverBase.wadDiv(params.debtPrice);
        uint256 collateralAmount = collateralToSeizeBase.wadDiv(
            params.collateralPrice
        );

        return LiquidationQuote(debtAmount, collateralAmount);
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
    ) internal pure returns (ThreePoolDistributionResult memory result) {
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
        
        // Step 4: Distribute remaining funds to three pools
        if (remainingFunds >= protocolSpreadShare + lpSpreadShare) {
            // Can pay all spread obligations
            result.protocolPool = protocolSpreadShare;
            result.lpSpreadPool = lpSpreadShare;
            
            // Distribute excess
            uint256 excess = remainingFunds - result.protocolPool - result.lpSpreadPool;
            uint256 lpExcessShare = excess.percentMul(input.lpShareOfRedeemed);
            result.lpSpreadPool += lpExcessShare;
            result.borrowerPool = excess - lpExcessShare;
        } else if (remainingFunds >= protocolSpreadShare) {
            // Can pay protocol fully, LP partially
            result.protocolPool = protocolSpreadShare;
            result.lpSpreadPool = remainingFunds - result.protocolPool;
            result.borrowerPool = 0;
        } else {
            // Can only pay protocol partially
            result.protocolPool = remainingFunds;
            result.lpSpreadPool = 0;
            result.borrowerPool = 0;
        }
        
        return result;
    }

    function calculateLpClaimAmount(
        CalcLpClaimInput memory input
    ) internal pure returns (uint256 claimAmount) {
        if (input.totalScaledSupplied == 0) return 0;
        
        uint256 userShare = input.scaledSupplyBalance.percentDiv(input.totalScaledSupplied);
        claimAmount = input.lpSpreadPool.percentMul(userShare);
        
        return claimAmount;
    }

    function calculateBorrowerClaimAmount(
        CalcBorrowerClaimInput memory input
    ) internal pure returns (uint256 claimAmount) {
        if (input.totalCollateral == 0) return 0;
        
        claimAmount = input.borrowerPool.mulDiv(
            input.positionCollateralAmount,
            input.totalCollateral
        );
        
        return claimAmount;
    }
}