// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/Core.sol";
import "../../src/libraries/Storage.sol";

contract CoreIntegrationTest is Test {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using Math for uint256;

    
    uint256 constant RAY = 1e27;
    uint256 constant WAD = 1e18;
    
    // ============ Real-World Scenario Tests ============
    
    function test_Scenario_PredictionMarketLifecycle() public {
        // Simulate full lifecycle: supply → borrow → accumulate → resolve
        
        // 1. Initial market setup
        Storage.ReserveData memory reserve = Storage.ReserveData({
            variableBorrowIndex: RAY,
            liquidityIndex: RAY,
            totalScaledBorrowed: 0,
            totalBorrowed: 0,
            totalScaledSupplied: 0,
            totalCollateral: 0,
            lastUpdateTimestamp: block.timestamp,
            cachedUtilization: 0,
            accumulatedSpread: 0,
            accumulatedRedeemed: 0,
            accumulatedReserves: 0
        });
        
        Storage.RiskParams memory params = _getRiskParams();
        
        // 2. LPs supply liquidity
        uint256 lpSupply = 1_000_000e6; // 1M USDC
        reserve.totalScaledSupplied = lpSupply;
        
        // 3. Multiple borrowers enter
        uint256[] memory borrowAmounts = new uint256[](3);
        borrowAmounts[0] = 200_000e6; // Borrower 1: 200k
        borrowAmounts[1] = 300_000e6; // Borrower 2: 300k  
        borrowAmounts[2] = 250_000e6; // Borrower 3: 250k
        
        uint256 totalBorrowed;
        for (uint i = 0; i < borrowAmounts.length; i++) {
            totalBorrowed += borrowAmounts[i];
        }
        
        reserve.totalScaledBorrowed = totalBorrowed;
        reserve.totalBorrowed = totalBorrowed;
        reserve.totalCollateral = 1500e18; // 1500 prediction tokens total
        
        // 4. Time passes - interest accumulates over 60 days
        vm.warp(block.timestamp + 60 days);
        
        Core.UpdateIndicesInput memory updateInput = Core.UpdateIndicesInput({
            reserve: reserve,
            riskParams: params
        });
        
        (uint256 finalBorrowIndex, uint256 finalLiquidityIndex) = Core.updateIndices(updateInput);
        
        // 5. Market resolves - tokens worth $0.80 each
        uint256 collateralPrice = 0.8e27;
        uint256 totalRedeemed = reserve.totalCollateral.mulDiv(collateralPrice, RAY)
            .mulDiv(10**6, 10**18); // Convert to USDC decimals
        
        // Calculate current debt with interest
        uint256 currentTotalDebt = reserve.totalScaledBorrowed.rayMul(finalBorrowIndex);
        uint256 spreadEarned = currentTotalDebt - reserve.totalBorrowed;
        
        console.log("=== Market Resolution Summary ===");
        console.log("Total Supplied:", lpSupply);
        console.log("Total Borrowed:", totalBorrowed);
        console.log("Utilization:", totalBorrowed * 100 / lpSupply, "%");
        console.log("Interest Accumulated:", spreadEarned);
        console.log("Collateral Redeemed:", totalRedeemed);
        console.log("Profit/Loss:", int256(totalRedeemed) - int256(currentTotalDebt));
        
        // 6. Distribute proceeds
        Core.CalcThreePoolDistributionInput memory distInput = Core.CalcThreePoolDistributionInput({
            totalCollateralRedeemed: totalRedeemed,
            aaveCurrentTotalDebt: totalBorrowed, // Principal only for this test
            accumulatedSpread: 0,
            currentBorrowIndex: finalBorrowIndex,
            totalScaledBorrowed: reserve.totalScaledBorrowed,
            totalNotScaledBorrowed: reserve.totalBorrowed,
            reserveFactor: 1000,
            lpShareOfRedeemed: 7000 // 70% to LPs in profit scenario
        });
        
        Core.ThreePoolDistributionResult memory distribution = Core.calculateThreePoolDistribution(distInput);
        
        console.log("=== Distribution ===");
        console.log("Aave Repayment:", distribution.aaveDebtRepaid);
        console.log("Protocol Revenue:", distribution.protocolPool);
        console.log("LP Pool:", distribution.lpSpreadPool);
        console.log("Borrower Pool:", distribution.borrowerPool);
        
        // Verify sensible distribution
        assertTrue(distribution.aaveDebtRepaid <= totalBorrowed, "Aave repayment bounded");
        assertTrue(distribution.protocolPool + distribution.lpSpreadPool + distribution.borrowerPool > 0, 
                  "Some distribution should occur");
    }
    
    function test_Scenario_HighVolatilityMarket() public {
        // Test protocol behavior with volatile prediction token prices
        Storage.RiskParams memory params = _getRiskParams();
        
        // User deposits tokens when price is high
        uint256 collateral = 100e18;
        uint256 highPrice = 0.9e27; // $0.90 per token
        
        Core.CalcMaxBorrowInput memory borrowInput = Core.CalcMaxBorrowInput({
            collateralAmount: collateral,
            collateralPrice: highPrice,
            ltv: params.ltv,
            supplyAssetDecimals: 6,
            collateralAssetDecimals: 18
        });
        
        uint256 maxBorrowHigh = Core.calculateBorrowAble(borrowInput);
        console.log("Max borrow at $0.90:", maxBorrowHigh);
        
        // Price drops significantly
        uint256 lowPrice = 0.3e27; // $0.30 per token
        borrowInput.collateralPrice = lowPrice;
        uint256 maxBorrowLow = Core.calculateBorrowAble(borrowInput);
        console.log("Max borrow at $0.30:", maxBorrowLow);
        
        // If user borrowed at high price, calculate health factor at low price
        uint256 borrowedAmount = maxBorrowHigh; // Borrowed max at high price
        
        Core.CalcHealthFactorInput memory healthInput = Core.CalcHealthFactorInput({
            collateralAmount: collateral,
            collateralPrice: lowPrice,
            userTotalDebt: borrowedAmount,
            liquidationThreshold: params.liquidationThreshold,
            supplyAssetDecimals: 6,
            collateralAssetDecimals: 18
        });
        
        // Note: Health factor calculation not in Core, but would show undercollateralization
        uint256 collateralValue = collateral.mulDiv(lowPrice, RAY).mulDiv(10**6, 10**18);
        uint256 liquidationValue = collateralValue.percentMul(params.liquidationThreshold);
        bool isLiquidatable = borrowedAmount > liquidationValue;
        
        console.log("Collateral value at low price:", collateralValue);
        console.log("Liquidation threshold value:", liquidationValue);
        console.log("Is liquidatable:", isLiquidatable);
        
        assertTrue(isLiquidatable, "Position should be liquidatable after price drop");
    }
    
    function test_Scenario_LPYieldOptimization() public {
        // Test LP returns under different utilization scenarios
        Storage.RiskParams memory params = _getRiskParams();
        uint256 lpSupply = 100_000e6;
        
        uint256[] memory utilizations = new uint256[](5);
        utilizations[0] = 0.2e27;  // 20%
        utilizations[1] = 0.5e27;  // 50%
        utilizations[2] = 0.8e27;  // 80% (optimal)
        utilizations[3] = 0.9e27;  // 90%
        utilizations[4] = 0.95e27; // 95%
        
        console.log("=== LP Yield Analysis ===");
        console.log("Utilization | Spread Rate | LP APY");
        console.log("------------|-------------|-------");
        
        for (uint i = 0; i < utilizations.length; i++) {
            uint256 borrowed = lpSupply.rayMul(utilizations[i]);
            
            Core.CalcSupplyRateInput memory input = Core.CalcSupplyRateInput({
                totalBorrowedPrincipal: borrowed,
                totalPolynanceSupply: lpSupply,
                riskParams: params
            });
            
            uint256 lpRate = Core.calculateSupplyRate(input);
            
            // Also calculate spread rate for reference
            Core.CalcPureSpreadRateInput memory spreadInput = Core.CalcPureSpreadRateInput({
                totalBorrowedPrincipal: borrowed,
                totalPolynanceSupply: lpSupply,
                riskParams: params
            });
            uint256 spreadRate = Core.calculateSpreadRate(spreadInput);
            
            console.log(
                string.concat(
                    _formatPercentage(utilizations[i]), " | ",
                    _formatPercentage(spreadRate), " | ",
                    _formatPercentage(lpRate)
                )
            );
        }
        
        // LPs get best yield around optimal utilization
        // But very high utilization also provides good returns
    }
    
    function test_Scenario_MarketMaturityEdgeCase() public {
        // Test behavior near market maturity date
        Storage.RiskParams memory params = _getRiskParams();
        params.limitDate = block.timestamp + 1 days; // Market matures tomorrow
        
        Storage.ReserveData memory reserve = _getActiveReserve();
        
        // Fast forward to 1 hour before maturity
        vm.warp(params.limitDate - 1 hours);
        
        // Interest should still accumulate normally
        Core.UpdateIndicesInput memory input = Core.UpdateIndicesInput({
            reserve: reserve,
            riskParams: params
        });
        
        (uint256 borrowIndex, uint256 liquidityIndex) = Core.updateIndices(input);
        
        assertGt(borrowIndex, reserve.variableBorrowIndex, "Interest accumulates until maturity");
        assertGt(liquidityIndex, reserve.liquidityIndex, "LP earnings accumulate until maturity");
        
        // Fast forward past maturity
        vm.warp(params.limitDate + 1 days);
        
        // After maturity, the shell contracts would typically freeze operations
        // But Core calculations should still work for final settlement
        reserve.variableBorrowIndex = borrowIndex;
        reserve.liquidityIndex = liquidityIndex;
        reserve.lastUpdateTimestamp = params.limitDate;
        
        (uint256 postMaturityBorrow, uint256 postMaturityLiquidity) = Core.updateIndices(input);
        
        assertGt(postMaturityBorrow, borrowIndex, "Can calculate final interest after maturity");
    }
    
    // ============ Helper Functions ============
    
    function _getRiskParams() internal view returns (Storage.RiskParams memory) {
        return Storage.RiskParams({
            interestRateMode: InterestRateMode.VARIABLE,
            baseSpreadRate: 0.02e27,
            optimalUtilization: 0.8e27,
            slope1: 0.04e27,
            slope2: 0.75e27,
            reserveFactor: 1000,
            ltv: 6000,
            liquidationThreshold: 7500,
            liquidationCloseFactor: 5000,
            liquidationBonus: 500, // 5% bonus for liquidators
            lpShareOfRedeemed: 7000, // 70% to LPs
            limitDate: block.timestamp + 90 days,
            priceOracle: address(0x1),
            liquidityLayer: address(0x2),
            supplyAsset: address(0x3),
            supplyAssetDecimals: 6,
            collateralAssetDecimals: 18,
            curator: address(0x5),
            isActive: true
        });
    }
    
    function _getActiveReserve() internal view returns (Storage.ReserveData memory) {
        return Storage.ReserveData({
            variableBorrowIndex: 1.02e27, // Some interest already accumulated
            liquidityIndex: 1.015e27,
            totalScaledBorrowed: 750_000e6,
            totalBorrowed: 765_000e6, // Reflects 2% interest
            totalScaledSupplied: 1_000_000e6,
            totalCollateral: 1200e18,
            lastUpdateTimestamp: block.timestamp - 30 days,
            cachedUtilization: 0.75e27,
            accumulatedSpread: 10_000e6,
            accumulatedRedeemed: 0,
            accumulatedReserves: 1_000e6
        });
    }
    
    function _formatPercentage(uint256 rayValue) internal pure returns (string memory) {
        uint256 percentage = rayValue / 1e25; // Convert RAY to basis points
        uint256 whole = percentage / 100;
        uint256 decimal = percentage % 100;
        
        return string.concat(
            vm.toString(whole),
            ".",
            decimal < 10 ? "0" : "",
            vm.toString(decimal),
            "%"
        );
    }
}