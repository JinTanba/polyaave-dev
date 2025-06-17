// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
library PolynanceEE {
    // ======== Events ========
    event Supply(address indexed supplier, uint256 amount, uint256 shares);
    event Borrow(address indexed borrower, uint256 amount, uint256 collateralAmount);
    event Repay(address indexed borrower, uint256 amount, uint256 remainingDebt);
    event IndicesUpdated(uint256 borrowIndex, uint256 liquidityIndex);
    event ReservesCollected(uint256 amount);
    event CollateralReturned(address indexed borrower, uint256 amount);
    event DepositCollateral(address indexed user, address indexed predictionAsset, uint256 collateralAmount);
    event DepositAndBorrow(address indexed borrower, address indexed predictionAsset, uint256 collateralAmount, uint256 borrowedAmount);
    
    // Market Resolution Events
    event MarketResolved(bytes32 indexed marketId, uint256 finalTokenPrice, uint256 totalCollateralValue, uint256 totalSystemDebt);
    event BorrowerPositionRedeemed(address indexed borrower, uint256 collateralReturned, uint256 surplusReceived);
    event LpPositionRedeemed(address indexed owner, uint256 tokenId, uint256 aaveAmount, uint256 spreadPoolAmount);
    event SupplyPositionRedeemed(address indexed supplier, uint256 tokenId, uint256 totalWithdrawn, uint256 deficitApplied);
    event DeficitCalculated(uint256 totalDeficit, uint256 deficitPerLPToken);
    event EmergencyResolution(bytes32 indexed marketId, address indexed resolver, uint256 emergencyPrice);
    
    // ======== Errors ========
    error MarketNotActive();
    error InvalidAmount();
    error InsufficientCollateral();
    error InsufficientLiquidity();
    error PositionUnhealthy();
    error BorrowCapExceeded();
    error UnauthorizedCaller();
    error ExcessiveRepayment();
    error NoDebtToRepay();
    error MarketNotMature();
    error NotCurator();

    error PositionHealthy();
    error NotImplemented();
    
    // Market Resolution Errors
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error InvalidResolutionPrice();
    error PositionAlreadyRedeemed();
    error NoPositionToRedeem();
    error RedemptionNotAllowed();
    error EmergencyResolutionNotAuthorized();
}