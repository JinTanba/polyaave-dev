// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum InterestRateMode {
    VARIABLE,
    FIXED
}

enum DataType {
    POOL_DATA,
    RISK_PARAMS,
    MARKET_DATA,
    USER_POSITION,
    RESOLUTION_DATA
}

struct PoolData {
    uint256 totalSupplied;
    uint256 totalBorrowedAllMarkets;
    uint256 totalAccumulatedSpread;
    uint256 totalAccumulatedReserves;
}

struct MarketData {
    address collateralAsset;
    uint256 collateralAssetDecimals;
    uint256 maturityDate;
    uint256 variableBorrowIndex;
    uint256 totalScaledBorrowed;
    uint256 totalBorrowed;
    uint256 totalCollateral;
    uint256 lastUpdateTimestamp;
    uint256 accumulatedSpread;
    bool isActive;
    bool isMatured;
}

struct UserPosition {
    uint256 collateralAmount;
    uint256 borrowAmount;
    uint256 scaledDebtBalance;
    uint256 lastUpdateTimestamp;
}

struct ResolutionData {
    bool isMarketResolved;
    uint256 marketResolvedTimestamp;
    uint256 finalCollateralPrice;
    uint256 lpPool;
    uint256 borrowerPool;
    uint256 protocolPool;
    uint256 totalCollateralRedeemed;
    uint256 liquidityRepaid;
    bool protocolClaimed;
}

struct RiskParams {
    address priceOracle;
    address liquidityLayer;
    address supplyAsset;
    address curator;
    uint256 baseSpreadRate;
    uint256 optimalUtilization;
    uint256 slope1;
    uint256 slope2;
    uint256 reserveFactor;
    uint256 ltv;
    uint256 liquidationThreshold;
    uint256 liquidationCloseFactor;
    uint256 liquidationBonus;
    uint256 lpShareOfRedeemed;
    uint256 supplyAssetDecimals;
}

// Core Input Structs
struct CoreSupplyInput {
    uint256 userLPBalance;
    uint256 supplyAmount;
}

struct CoreBorrowInput {
    uint256 borrowAmount;
    uint256 collateralAmount;
    uint256 collateralPrice;
    uint256 protocolTotalDebt;
}

struct CoreRepayInput {
    uint256 repayAmount;
    uint256 protocolTotalDebt;
}

struct CoreLiquidationInput {
    uint256 repayAmount;
    uint256 collateralPrice;
    uint256 protocolTotalDebt;
}

struct CoreResolutionInput {
    uint256 totalCollateralRedeemed;
    uint256 liquidityLayerDebt;
}

struct CoreLPRedemptionInput {
    uint256 userLPBalance;
    uint256 liquidityBalance;
}

// Core output Aux
struct CoreSupplyOutput {
    uint256 newUserLPBalance;
    uint256 lpTokensToMint;
}

struct CoreBorrowOutput {
    uint256 actualBorrowAmount;
}

struct CoreRepayOutput {
    uint256 actualRepayAmount;
    uint256 liquidityRepayAmount;
    uint256 totalDebt;
    uint256 collateralToReturn;
}

struct CoreLiquidationOutput {
    uint256 actualRepayAmount;
    uint256 collateralSeized;
}

struct CoreLPRedemptionOutput {
    uint256 redeemAmount;
    uint256 tokenValue;
}

