// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../interfaces/IPositionToken.sol";
import "../../interfaces/ILiquidityLayer.sol";
import "../Storage.sol";
import "../../Core.sol";
import "../PolynanceEE.sol";
import "../../interfaces/Oralce.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/protocol/libraries/math/PercentageMath.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

library MarketResolveLogic {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using Math for uint256;

    uint256 private constant MAX_BPS = 10_000;
    
    struct ResolveInput {
        bytes32 marketId;
        address resolver;
    }
    
    function resolve(ResolveInput memory input) internal {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        Storage.ReserveData storage reserve = Core.getReserveData(input.marketId);
        Storage.ResolutionData storage resolution = Core.getResolutionData(input.marketId);
        
        if (resolution.isMarketResolved) revert PolynanceEE.MarketAlreadyResolved();
        if (block.timestamp < rp.maturityDate) revert PolynanceEE.MarketNotMature();
        if (input.resolver != rp.curator) revert PolynanceEE.NotCurator();
        
        // Step 1: Redeem all collateral
        uint256 totalCollateralRedeemed = _redeemAllCollateral(rp);
        
        // Step 2: Get current Aave debt
        ILiquidityLayer aave = ILiquidityLayer(rp.liquidityLayer);
        uint256 aaveCurrentTotalDebt = aave.getDebtBalance(rp.supplyAsset, address(this), rp.interestRateMode);
        
        // Step 3: Use pure function to calculate three-pool distribution
        Core.ThreePoolDistributionResult memory pools = Core.calculateThreePoolDistribution(
            Core.CalcThreePoolDistributionInput({
                totalCollateralRedeemed: totalCollateralRedeemed,
                aaveCurrentTotalDebt: aaveCurrentTotalDebt,
                accumulatedSpread: reserve.accumulatedSpread,
                currentBorrowIndex: reserve.variableBorrowIndex,
                totalNotScaledBorrowed: reserve.totalBorrowed,
                totalScaledBorrowed: reserve.totalScaledBorrowed,
                reserveFactor: rp.reserveFactor,
                lpShareOfRedeemed: rp.lpShareOfRedeemed
            })
        );
        
        // Step 4: Repay Aave immediately
        if (pools.aaveDebtRepaid > 0) {
            _repayAaveConsolidated(rp, pools.aaveDebtRepaid);
        }
        
        // Step 5: Store resolution data
        resolution.isMarketResolved = true;
        resolution.marketResolvedTimestamp = block.timestamp;
        resolution.finalCollateralPrice = IOracle(rp.priceOracle).getCurrentPrice(rp.collateralAsset);
        resolution.lpSpreadPool = pools.lpSpreadPool;
        resolution.borrowerPool = pools.borrowerPool;
        resolution.protocolPool = pools.protocolPool;
        resolution.totalCollateralRedeemed = totalCollateralRedeemed;
        resolution.aaveDebtRepaid = pools.aaveDebtRepaid;
        
        emit PolynanceEE.MarketResolved(
            input.marketId,
            resolution.finalCollateralPrice,
            totalCollateralRedeemed,
            aaveCurrentTotalDebt + reserve.accumulatedSpread + reserve.totalScaledBorrowed.rayMul(reserve.variableBorrowIndex)
        );
        
        rp.isActive = false;
    }
    
    function _redeemAllCollateral(
        Storage.RiskParams storage rp
    ) private returns (uint256 totalValue) {
        uint256 balanceBefore = IERC20(rp.supplyAsset).balanceOf(address(this));
        
        IPositionToken(rp.collateralAsset).redeem();
        
        uint256 balanceAfter = IERC20(rp.supplyAsset).balanceOf(address(this));
        totalValue = balanceAfter - balanceBefore;
        
        return totalValue;
    }
    
    function _repayAaveConsolidated(
        Storage.RiskParams storage rp,
        uint256 amount
    ) private {
        if (amount == 0) return;
        
        ILiquidityLayer aave = ILiquidityLayer(rp.liquidityLayer);
        aave.repay(rp.supplyAsset, amount, rp.interestRateMode, address(this));
    }
    
    function _withdrawFromAave(
        Storage.RiskParams storage rp,
        uint256 amount,
        address recipient
    ) private {
        ILiquidityLayer aave = ILiquidityLayer(rp.liquidityLayer);
        aave.withdraw(rp.supplyAsset, amount, recipient);
    }
    
    function claimBorrowerPosition(bytes32 marketId, address borrower) internal {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        Storage.ResolutionData storage resolution = Core.getResolutionData(marketId);
        Storage.ReserveData storage reserve = Core.getReserveData(marketId);
        
        if (!resolution.isMarketResolved) revert PolynanceEE.MarketNotResolved();
        if (resolution.borrowerClaimed[borrower]) revert PolynanceEE.PositionAlreadyRedeemed();
        
        Storage.UserPosition storage position = Core.getUserPosition(marketId, borrower);
        if (position.collateralAmount == 0) revert PolynanceEE.NoPositionToRedeem();
        
        // Use pure function to calculate borrower's share from borrower pool
        uint256 borrowerPayout = Core.calculateBorrowerClaimAmount(
            Core.CalcBorrowerClaimInput({
                positionCollateralAmount: position.collateralAmount,
                totalCollateral: reserve.totalCollateral,
                borrowerPool: resolution.borrowerPool
            })
        );
        
        resolution.borrowerClaimed[borrower] = true;
        
        if (borrowerPayout > 0) {
            IERC20(rp.supplyAsset).safeTransfer(borrower, borrowerPayout);
        }
        
        emit PolynanceEE.BorrowerPositionRedeemed(borrower, position.collateralAmount, borrowerPayout);
        
        // Clear position
        position.collateralAmount = 0;
        position.borrowAmount = 0;
        position.scaledDebtBalance = 0;
    }
    
    function claimLpPosition(bytes32 marketId, uint256 tokenId) internal returns (uint256) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams storage rp = $.riskParams;
        Storage.SupplyPosition storage position = $.supplyPositions[tokenId];
        Storage.ResolutionData storage resolution = Core.getResolutionData(marketId);
        Storage.ReserveData storage reserve = Core.getReserveData(marketId);
        
        if (!resolution.isMarketResolved) revert PolynanceEE.MarketNotResolved();
        if (resolution.lpTokenClaimed[tokenId]) revert PolynanceEE.PositionAlreadyRedeemed();
        if (position.supplyAmount == 0) revert PolynanceEE.NoPositionToRedeem();

        // Calculate LP's share from spread pool
        uint256 spreadPoolPayout = Core.calculateLpClaimAmount(
            Core.CalcLpClaimInput({
                scaledSupplyBalance: position.scaledSupplyBalance,
                totalScaledSupplied: reserve.totalScaledSupplied,
                lpSpreadPool: resolution.lpSpreadPool
            })
        );
        
        // Calculate LP's share of Aave balance
        uint256 userShare = position.scaledSupplyBalance.percentDiv(reserve.totalScaledSupplied);
        uint256 currentAaveBalance = ILiquidityLayer(rp.liquidityLayer).getSupplyBalance(rp.supplyAsset, address(this));
        uint256 userAaveAmount = currentAaveBalance.percentMul(userShare);
        
        resolution.lpTokenClaimed[tokenId] = true;
        
        address owner = ERC721(address(this)).ownerOf(tokenId);
        
        // Withdraw user's portion from Aave directly to owner
        if (userAaveAmount > 0) {
            _withdrawFromAave(rp, userAaveAmount, owner);
        }
        
        // Transfer spread pool payout
        if (spreadPoolPayout > 0) {
            IERC20(rp.supplyAsset).safeTransfer(owner, spreadPoolPayout);
        }
        
        // Clear position
        position.scaledSupplyBalance = 0;
        
        uint256 totalPayout = userAaveAmount + spreadPoolPayout;
        
        // emit PolynanceEE.LpPositionRedeemed(owner, tokenId, userAaveAmount, spreadPoolPayout);
        
        return totalPayout;
    }
    
}