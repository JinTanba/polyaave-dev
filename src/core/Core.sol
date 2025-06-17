// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./CoreMath.sol";
import "../libraries/DataStruct.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Core
 * @notice Abstract contract that performs state transitions using CoreMath
 * @dev All state changes go through this contract, all calculations through CoreMath
 */
contract Core {
    uint256 internal constant RAY = 1e27;
    
    // ============ State Change Functions ============
    
    /**
     * @notice Update market indices based on elapsed time
     * @dev Updates variableBorrowIndex and tracks accumulated spread
     */
    function _updateMarketIndices(
        MarketData memory market,
        PoolData memory pool,
        RiskParams memory params
    ) internal view returns (
        MarketData memory,
        PoolData memory
    ) {
        if (market.lastUpdateTimestamp == 0) {
            market.variableBorrowIndex = RAY;
            market.lastUpdateTimestamp = block.timestamp;
            return (market, pool);
        }
        
        if (block.timestamp == market.lastUpdateTimestamp) return (market, pool);
        
        // Calculate new borrow index using pool's total supply
        uint256 spreadRate = CoreMath.calculateSpreadRate(
            market.totalBorrowed,
            pool.totalSupplied,
            params.baseSpreadRate,
            params.optimalUtilization,
            params.slope1,
            params.slope2
        );
        
        uint256 newBorrowIndex = CoreMath.calculateNewBorrowIndex(
            market.variableBorrowIndex,
            spreadRate,
            market.lastUpdateTimestamp
        );
        
        // Calculate and accumulate spread earned
        uint256 spreadEarned = CoreMath.calculateSpreadEarned(
            market.totalScaledBorrowed,
            newBorrowIndex,
            market.totalBorrowed
        );
        
        // Update state
        market.variableBorrowIndex = newBorrowIndex;
        market.accumulatedSpread += spreadEarned;
        market.lastUpdateTimestamp = block.timestamp;
        
        // Update pool accumulated spread
        pool.totalAccumulatedSpread += spreadEarned;
        
        return (market, pool);
    }
    
    function processSupply(
        PoolData memory pool,
        CoreSupplyInput memory input
    ) external pure returns (
        PoolData memory newPool,
        CoreSupplyOutput memory aux
    ) {
        require(input.supplyAmount > 0, "Invalid supply amount");
        
        newPool = pool;
        
        // Calculate LP tokens (V2: always 1:1)
        uint256 lpTokensToMint = CoreMath.calculateLPTokensToMint(input.supplyAmount);
        
        // Update pool state
        newPool.totalSupplied += input.supplyAmount;
        
        aux = CoreSupplyOutput({
            newUserLPBalance: input.userLPBalance + lpTokensToMint,
            lpTokensToMint: lpTokensToMint
        });
        
        return (newPool, aux);
    }
    
    /**
     * @notice Process borrow operation
     * @param market Market state to update
     * @param pool Pool state for liquidity check
     * @param position User position to update
     * @param input Borrow input parameters
     * @param params Risk parameters
     */
    function processBorrow(
        MarketData memory market,
        PoolData memory pool,
        UserPosition memory position,
        CoreBorrowInput memory input,
        RiskParams memory params
    ) external pure returns(
        MarketData memory,
        PoolData memory,
        UserPosition memory,
        CoreBorrowOutput memory
    ) {
        // Update collateral
        position.collateralAmount += input.collateralAmount;
        market.totalCollateral += input.collateralAmount;
        
        // Calculate collateral value and max borrow
        uint256 totalCollateralValue = CoreMath.calculateCollateralValue(
            position.collateralAmount,
            input.collateralPrice,
            params.supplyAssetDecimals,
            market.collateralAssetDecimals
        );
        
        uint256 maxBorrow = CoreMath.calculateMaxBorrow(
            totalCollateralValue,
            params.ltv
        );
        
        uint256 actualBorrowAmount = input.borrowAmount > maxBorrow ? maxBorrow : input.borrowAmount;
        
        // Calculate scaled debt for Polynance spread tracking
        uint256 scaledPolynanceDebt = CoreMath.calculateScaledDebt(
            actualBorrowAmount,
            market.variableBorrowIndex
        );
        
        // Update position
        position.borrowAmount += actualBorrowAmount;
        position.scaledDebtBalance += scaledPolynanceDebt;
        
        // Update market state
        market.totalBorrowed += actualBorrowAmount;
        market.totalScaledBorrowed += scaledPolynanceDebt;
        
        // Update pool state
        pool.totalBorrowedAllMarkets += actualBorrowAmount;
        
        CoreBorrowOutput memory aux = CoreBorrowOutput({
            actualBorrowAmount: actualBorrowAmount
        });
        
        return (market, pool, position, aux);
    }
    
    /**
     * @notice Process repay operation
     * @param market Market state to update
     * @param pool Pool state
     * @param position User position to update
     * @param input Repay input parameters
     * @return newMarket Updated market state
     * @return newPool Updated pool state
     * @return newPosition Updated position state
     * @return aux Repay aux parameters
     */
    function processRepay(
        MarketData memory market,
        PoolData memory pool,
        UserPosition memory position,
        CoreRepayInput memory input
    ) public pure returns (
        MarketData memory newMarket,
        PoolData memory newPool,
        UserPosition memory newPosition,
        CoreRepayOutput memory aux
    ) {
        newMarket = market;
        newPool = pool;
        newPosition = position;

        uint256 actualRepayAmount = newPosition.borrowAmount > input.repayAmount ? input.repayAmount : newPosition.borrowAmount;
        // Calculate user's principal debt using ratios
        uint256 userPrincipalDebt = _calculateUserPrincipalDebt(
            actualRepayAmount,
            newMarket.totalBorrowed,
            newPool.totalBorrowedAllMarkets,
            input.protocolTotalDebt
        );
        
        // Get current debt components
        (uint256 totalDebt, uint256 principalDebt,) = CoreMath.calculateUserTotalDebt(
            input.repayAmount,
            newMarket.totalBorrowed,
            userPrincipalDebt,
            newPosition.scaledDebtBalance,
            newMarket.variableBorrowIndex
        );

        uint256 currentRepayReduction = Math.mulDiv(
            actualRepayAmount,
            actualRepayAmount,
            newPosition.borrowAmount
        );
        uint256 scaledCurrentRepayReduction = CoreMath.calculateScaledDebt(currentRepayReduction, newMarket.variableBorrowIndex);
        uint256 collateralToReturn = Math.mulDiv(
            newPosition.collateralAmount,
            actualRepayAmount,
            newPosition.borrowAmount
        );
        newPosition.scaledDebtBalance -= scaledCurrentRepayReduction;
        newPosition.borrowAmount -= currentRepayReduction;
        newPosition.collateralAmount -= collateralToReturn;

        newMarket.totalBorrowed -= currentRepayReduction;
        newMarket.totalScaledBorrowed -= scaledCurrentRepayReduction;
        newMarket.totalCollateral -= collateralToReturn;

        newPool.totalBorrowedAllMarkets -= currentRepayReduction;

        aux = CoreRepayOutput({
            actualRepayAmount: actualRepayAmount,
            liquidityRepayAmount: principalDebt,
            totalDebt: totalDebt,
            collateralToReturn: collateralToReturn
        });
        
        return (newMarket, newPool, newPosition, aux);
    }
    
    /**
     * @notice Process liquidation
     * @param market Market state to update
     * @param pool Pool state
     * @param position Position being liquidated
     * @param input Liquidation input parameters
     * @param params Risk parameters
     * @return newMarket Updated market state
     * @return newPool Updated pool state
     * @return newPosition Updated position state
     * @return aux Liquidation aux parameters
     */
    function processLiquidation(
        MarketData memory market,
        PoolData memory pool,
        UserPosition memory position,
        CoreLiquidationInput memory input,
        RiskParams memory params
    ) external pure returns (
        MarketData memory newMarket,
        PoolData memory newPool,
        UserPosition memory newPosition,
        CoreLiquidationOutput memory aux
    ) {
        // Calculate current debt and health factor
        (uint256 totalDebt, , ) = getUserDebt(market, pool, position, input.protocolTotalDebt);
        
        uint256 collateralValue = CoreMath.calculateCollateralValue(
            position.collateralAmount,
            input.collateralPrice,
            params.supplyAssetDecimals,
            market.collateralAssetDecimals
        );
        
        uint256 healthFactor = CoreMath.calculateHealthFactor(
            collateralValue,
            totalDebt,
            params.liquidationThreshold
        );
        
        require(healthFactor < RAY, "Position healthy");
        
        // Calculate max liquidatable
        uint256 maxLiquidatable = CoreMath.calculateMaxLiquidatable(
            totalDebt,
            params.liquidationCloseFactor
        );
        
        uint256 requestedRepay = input.repayAmount > maxLiquidatable ? maxLiquidatable : input.repayAmount;
        
        // Process repayment
        CoreRepayInput memory repayInput = CoreRepayInput({
            repayAmount: requestedRepay,
            protocolTotalDebt: input.protocolTotalDebt
        });
        
        CoreRepayOutput memory repayOutput;
        (newMarket, newPool, newPosition, repayOutput) = processRepay(
            market, 
            pool,
            position, 
            repayInput
        );
        
        aux = CoreLiquidationOutput({
            actualRepayAmount: repayOutput.actualRepayAmount,
            collateralSeized: repayOutput.collateralToReturn
        });
        
        return (newMarket, newPool, newPosition, aux);
    }
    
    /**
     * @notice Calculate and store resolution distribution
     * @param market Market state
     * @param pool Pool state
     * @param resolution Resolution state to update
     * @param input Resolution input parameters
     * @param params Risk parameters
     */
    function processResolution(
        MarketData memory market,
        PoolData memory pool,
        ResolutionData memory resolution,
        CoreResolutionInput memory input,
        RiskParams memory params
    ) external view returns (
        MarketData memory newMarket,
        PoolData memory newPool,
        ResolutionData memory newResolution
    ) {
        require(!resolution.isMarketResolved, "Already resolved");
        
        newResolution = resolution;
        
        // Update indices one final time
        (newMarket, newPool) = _updateMarketIndices(market, pool, params);
        
        // Calculate total spread for this market
        uint256 marketSpread = newMarket.accumulatedSpread + CoreMath.calculateSpreadEarned(
            newMarket.totalScaledBorrowed,
            newMarket.variableBorrowIndex,
            newMarket.totalBorrowed
        );
        
        // Distribute spread
        (uint256 protocolSpread, uint256 lpSpread) = CoreMath.distributeSpread(
            marketSpread,
            params.reserveFactor
        );
        
        // Calculate three-pool distribution
        (
            uint256 liquidityRepayment,
            uint256 protocolPool,
            uint256 lpPool,
            uint256 borrowerPool
        ) = CoreMath.calculateResolutionPools(
            input.totalCollateralRedeemed,
            input.liquidityLayerDebt,
            protocolSpread,
            lpSpread,
            params.lpShareOfRedeemed
        );
        
        // Update resolution state
        newResolution.isMarketResolved = true;
        newResolution.marketResolvedTimestamp = block.timestamp;
        newResolution.totalCollateralRedeemed = input.totalCollateralRedeemed;
        newResolution.liquidityRepaid = liquidityRepayment;
        newResolution.protocolPool = protocolPool;
        newResolution.lpPool = lpPool;
        newResolution.borrowerPool = borrowerPool;
        
        // Update pool reserves
        newPool.totalAccumulatedReserves += protocolPool;
        
        return (newMarket, newPool, newResolution);
    }
    
    /**
     * @notice Calculate LP redemption value
     * @param pool Pool state
     * @param resolution Resolution state
     * @param input LP redemption input parameters
     * @return aux LP redemption aux parameters
     */
    function calculateLPRedemption(
        PoolData memory pool,
        ResolutionData memory resolution,
        CoreLPRedemptionInput memory input
    ) external pure returns (
        CoreLPRedemptionOutput memory aux
    ) {
        require(resolution.isMarketResolved, "Market not resolved");
        
        (uint256 tokenValue, ) = CoreMath.calculateLPTokenValue(
            resolution.lpPool,
            input.liquidityBalance,
            pool.totalSupplied,  // LP token supply = total supplied
            pool.totalSupplied
        );
        
        uint256 redeemAmount = CoreMath.calculateLPClaim(input.userLPBalance, tokenValue);
        
        aux = CoreLPRedemptionOutput({
            redeemAmount: redeemAmount,
            tokenValue: tokenValue
        });
        
        return aux;
    }
    
    /**
     * @notice Calculate borrower rebate
     * @param market Market state
     * @param resolution Resolution state
     * @param position User position
     * @return rebateAmount Amount of rebate
     */
    function calculateBorrowerRebate(
        MarketData memory market,
        ResolutionData memory resolution,
        UserPosition memory position
    ) external pure returns (uint256 rebateAmount) {
        require(resolution.isMarketResolved, "Market not resolved");
        
        return CoreMath.calculateBorrowerRebate(
            position.collateralAmount,
            market.totalCollateral,
            resolution.borrowerPool
        );
    }
    
    // ============ Internal Helper Functions ============
    
    /**
     * @notice Calculate user's principal debt based on ratios
     * @param userBorrowAmount User's initial borrow amount
     * @param marketTotalBorrowed Market's total initial borrowed
     * @param protocolTotalBorrowed Protocol's total borrowed across all markets
     * @param protocolTotalDebt Total protocol debt from liquidity layer
     * @return userPrincipalDebt User's share of principal debt
     */
    function _calculateUserPrincipalDebt(
        uint256 userBorrowAmount,
        uint256 marketTotalBorrowed,
        uint256 protocolTotalBorrowed,
        uint256 protocolTotalDebt
    ) internal pure returns (uint256 userPrincipalDebt) {
        if (marketTotalBorrowed == 0 || protocolTotalBorrowed == 0) return 0;
        
        // Calculate market's share of protocol debt
        uint256 marketDebt = Math.mulDiv(
            protocolTotalDebt,
            marketTotalBorrowed,
            protocolTotalBorrowed
        );
        
        // Calculate user's share of market debt
        userPrincipalDebt = Math.mulDiv(
            marketDebt,
            userBorrowAmount,
            marketTotalBorrowed
        );
        
        return userPrincipalDebt;
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get current utilization rate for a market
     */
    function getUtilization(
        MarketData memory market,
        PoolData memory pool
    ) external pure returns (uint256) {
        return CoreMath.calculateUtilization(market.totalBorrowed, pool.totalSupplied);
    }
    
    /**
     * @notice Get current spread rate for a market
     */
    function getSpreadRate(
        MarketData memory market,
        PoolData memory pool,
        RiskParams memory params
    ) external pure returns (uint256) {
        return CoreMath.calculateSpreadRate(
            market.totalBorrowed,
            pool.totalSupplied,
            params.baseSpreadRate,
            params.optimalUtilization,
            params.slope1,
            params.slope2
        );
    }
    
    /**
     * @notice Get user's current total debt
     * @param market Market state
     * @param pool Pool state
     * @param position User position
     * @param protocolTotalDebt Total protocol debt from liquidity layer
     * @return totalDebt Total debt (principal + spread)
     * @return principalDebt Principal debt including liquidity layer interest
     * @return spreadDebt Polynance spread only
     */
    function getUserDebt(
        MarketData memory market,
        PoolData memory pool,
        UserPosition memory position,
        uint256 protocolTotalDebt
    ) public pure returns (
        uint256 totalDebt,
        uint256 principalDebt,
        uint256 spreadDebt
    ) {
        // Calculate user's principal debt using ratios
        uint256 userPrincipalDebt = _calculateUserPrincipalDebt(
            position.borrowAmount,
            market.totalBorrowed,
            pool.totalBorrowedAllMarkets,
            protocolTotalDebt
        );
        
        return CoreMath.calculateUserTotalDebt(
            position.borrowAmount,
            market.totalBorrowed,
            userPrincipalDebt,
            position.scaledDebtBalance,
            market.variableBorrowIndex
        );
    }
    
    /**
     * @notice Get user's health factor
     */
    function getUserHealthFactor(
        MarketData memory market,
        PoolData memory pool,
        UserPosition memory position,
        uint256 collateralPrice,
        uint256 protocolTotalDebt,
        RiskParams memory params
    ) external pure returns (uint256) {
        (uint256 totalDebt, , ) = getUserDebt(market, pool, position, protocolTotalDebt);
        
        uint256 collateralValue = CoreMath.calculateCollateralValue(
            position.collateralAmount,
            collateralPrice,
            params.supplyAssetDecimals,
            market.collateralAssetDecimals
        );
        
        return CoreMath.calculateHealthFactor(
            collateralValue,
            totalDebt,
            params.liquidationThreshold
        );
    }
}