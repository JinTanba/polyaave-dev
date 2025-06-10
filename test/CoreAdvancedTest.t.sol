// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/Core.sol";
import "../src/libraries/Storage.sol";

contract CoreAdvancedTest is Test {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    
    uint256 constant RAY = 1e27;
    uint256 constant WAD = 1e18;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    
    // ============ Time-Based Interest Accumulation Tests ============
    
    function test_CompoundInterestAccumulation_MultipleUpdates() public {
        // Test realistic interest accumulation over multiple time periods
        Storage.ReserveData memory reserve = _getInitialReserve();
        Storage.RiskParams memory riskParams = _getRiskParams();
        
        uint256[] memory timeDeltas = new uint256[](4);
        timeDeltas[0] = 30 days;  // Month 1
        timeDeltas[1] = 30 days;  // Month 2
        timeDeltas[2] = 30 days;  // Month 3
        timeDeltas[3] = 275 days; // Rest of year
        
        uint256 currentBorrowIndex = reserve.variableBorrowIndex;
        uint256 currentLiquidityIndex = reserve.liquidityIndex;
        
        for (uint256 i = 0; i < timeDeltas.length; i++) {
            vm.warp(block.timestamp + timeDeltas[i]);
            
            Core.UpdateIndicesInput memory input = Core.UpdateIndicesInput({
                reserve: reserve,
                riskParams: riskParams
            });
            
            (currentBorrowIndex, currentLiquidityIndex) = Core.updateIndices(input);
            
            // Update reserve for next iteration
            reserve.variableBorrowIndex = currentBorrowIndex;
            reserve.liquidityIndex = currentLiquidityIndex;
            reserve.lastUpdateTimestamp = block.timestamp;
            
            console.log("After period", i + 1);
            console.log("Borrow Index:", currentBorrowIndex);
            console.log("Liquidity Index:", currentLiquidityIndex);
        }
        
        // After 1 year with 80% utilization, indexes should have grown appropriately
        assertGt(currentBorrowIndex, 1.05e27, "Borrow index should grow > 5%");
        assertGt(currentLiquidityIndex, 1.04e27, "Liquidity index should grow > 4%");
    }
    
    function test_InterestAccumulation_VariableUtilization() public {
        // Test interest accumulation with changing utilization rates
        Storage.ReserveData memory reserve = _getInitialReserve();
        Storage.RiskParams memory riskParams = _getRiskParams();
        
        // Scenario: Utilization changes over time
        uint256[] memory borrowAmounts = new uint256[](3);
        borrowAmounts[0] = 50_000e6;  // 50% utilization
        borrowAmounts[1] = 85_000e6;  // 85% utilization (above optimal)
        borrowAmounts[2] = 40_000e6;  // 40% utilization
        
        for (uint256 i = 0; i < borrowAmounts.length; i++) {
            // Update reserve state
            reserve.totalScaledBorrowed = borrowAmounts[i];
            reserve.totalBorrowed = borrowAmounts[i];
            
            // Fast forward 90 days
            vm.warp(block.timestamp + 90 days);
            
            Core.UpdateIndicesInput memory input = Core.UpdateIndicesInput({
                reserve: reserve,
                riskParams: riskParams
            });
            
            (uint256 newBorrowIndex, uint256 newLiquidityIndex) = Core.updateIndices(input);
            
            console.log("Period", i + 1, "- Utilization:", borrowAmounts[i] * 100 / 100_000e6);
            console.log("Borrow Index Growth:", newBorrowIndex - reserve.variableBorrowIndex);
            console.log("Liquidity Index Growth:", newLiquidityIndex - reserve.liquidityIndex);
            
            reserve.variableBorrowIndex = newBorrowIndex;
            reserve.liquidityIndex = newLiquidityIndex;
            reserve.lastUpdateTimestamp = block.timestamp;
        }
    }
    
    // ============ Complex Market Resolution Scenarios ============
    
    function test_MarketResolution_PartialSpreadPayment() public {
        // Scenario: Enough to pay Aave + protocol but only partial LP spread
        uint256 aaveDebt = 100_000e6;
        uint256 totalSpread = 10_000e6; // 10k total spread
        uint256 protocolShare = totalSpread.percentMul(1000); // 1k to protocol
        uint256 lpSpreadShare = totalSpread - protocolShare; // 9k to LPs
        
        // Redeemed amount covers Aave + protocol + half of LP spread
        uint256 redeemed = aaveDebt + protocolShare + (lpSpreadShare / 2);
        
        Core.CalcThreePoolDistributionInput memory input = Core.CalcThreePoolDistributionInput({
            totalCollateralRedeemed: redeemed,
            aaveCurrentTotalDebt: aaveDebt,
            accumulatedSpread: 8_000e6,
            currentBorrowIndex: 1.025e27,
            totalScaledBorrowed: 100_000e6,
            totalNotScaledBorrowed: 100_000e6,
            reserveFactor: 1000,
            lpShareOfRedeemed: 5000
        });
        
        Core.ThreePoolDistributionResult memory result = Core.calculateThreePoolDistribution(input);
        
        assertEq(result.aaveDebtRepaid, aaveDebt, "Aave should be fully paid");
        assertEq(result.protocolPool, protocolShare, "Protocol should be fully paid");
        assertEq(result.lpSpreadPool, lpSpreadShare / 2, "LPs get partial payment");
        assertEq(result.borrowerPool, 0, "No excess for borrowers");
    }
    
    function test_MarketResolution_LargeExcessDistribution() public {
        // Scenario: Prediction market resolves very favorably
        Core.CalcThreePoolDistributionInput memory input = Core.CalcThreePoolDistributionInput({
            totalCollateralRedeemed: 500_000e6, // 500k redeemed (5x the debt)
            aaveCurrentTotalDebt: 80_000e6,
            accumulatedSpread: 5_000e6,
            currentBorrowIndex: 1.05e27,
            totalScaledBorrowed: 80_000e6,
            totalNotScaledBorrowed: 80_000e6,
            reserveFactor: 1000, // 10%
            lpShareOfRedeemed: 3000 // 30% to LPs, 70% to borrowers
        });
        
        Core.ThreePoolDistributionResult memory result = Core.calculateThreePoolDistribution(input);
        
        uint256 totalSpread = 9_000e6;
        uint256 protocolSpread = totalSpread.percentMul(1000);
        uint256 lpSpread = totalSpread - protocolSpread;
        uint256 excess = 500_000e6 - 80_000e6 - totalSpread;
        uint256 lpExcessShare = excess.percentMul(3000);
        
        assertEq(result.aaveDebtRepaid, 80_000e6, "Aave fully repaid");
        assertEq(result.protocolPool, protocolSpread, "Protocol gets spread share");
        assertEq(result.lpSpreadPool, lpSpread + lpExcessShare, "LPs get spread + excess share");
        assertEq(result.borrowerPool, excess - lpExcessShare, "Borrowers get remaining excess");
        
        // Verify total distribution equals redeemed amount
        uint256 totalDistributed = result.aaveDebtRepaid + result.protocolPool + 
                                  result.lpSpreadPool + result.borrowerPool;
        assertEq(totalDistributed, 500_000e6, "All funds should be distributed");
    }
    
    // ============ Precision and Rounding Tests ============
    
    function test_ScaledCalculations_Precision() public {
        // Test precision in scaled calculations with various decimal combinations
        
        // Test 1: Small borrow amount with high index
        uint256 borrowAmount = 1e6; // 1 USDC
        uint256 highIndex = 1.999999999e27; // Almost 2x
        
        uint256 scaledPrincipal = Core.calculateScaledValue(borrowAmount, highIndex);
        uint256 reconstructed = scaledPrincipal.rayMul(highIndex);
        
        // Should maintain precision within 1 wei for USDC
        assertApproxEqAbs(reconstructed, borrowAmount, 1, "Precision loss in scaling");
        
        // Test 2: Large borrow with fractional index
        borrowAmount = 999_999e6; // ~1M USDC
        uint256 fractionalIndex = 1.123456789e27;
        
        scaledPrincipal = Core.calculateScaledValue(borrowAmount, fractionalIndex);
        reconstructed = scaledPrincipal.rayMul(fractionalIndex);
        
        assertApproxEqAbs(reconstructed, borrowAmount, 1000, "Acceptable precision for large amounts");
    }
    
    function test_InterestCalculation_SmallAmounts() public {
        // Test interest calculation with very small principal amounts
        Core.CalcUserTotalDebtInput memory input = Core.CalcUserTotalDebtInput({
            principalDebt: 10e6, // 10 USDC
            scaledPolynanceSpreadDebtPrincipal: 10e6,
            initialBorrowAmount: 10e6,
            currentPolynanceSpreadBorrowIndex: 1.001e27 // 0.1% interest
        });
        
        (uint256 totalDebt, , uint256 spreadInterest) = Core.calculateUserTotalDebt(input);
        
        // Even small amounts should accrue some interest
        assertGt(spreadInterest, 0, "Should accrue interest on small amounts");
        assertEq(totalDebt, 10e6 + spreadInterest, "Total debt calculation");
    }
    
    // ============ Extreme Market Conditions Tests ============
    
    function test_ExtremeUtilization_99Percent() public {
        // Test system behavior at extreme utilization
        Core.CalcPureSpreadRateInput memory input = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: 99_900e6, // 99.9% utilization
            totalPolynanceSupply: 100_000e6,
            riskParams: _getRiskParams()
        });
        
        uint256 spreadRate = Core.calculateSpreadRate(input);
        
        // At 99.9% utilization, rate should be very high but not overflow
        assertGt(spreadRate, 0.5e27, "Spread rate should be > 50% at extreme utilization");
        assertLt(spreadRate, 2e27, "Spread rate should still be reasonable");
        
        // Test supply rate at extreme utilization
        Core.CalcSupplyRateInput memory supplyInput = Core.CalcSupplyRateInput({
            totalBorrowedPrincipal: 99_900e6,
            totalPolynanceSupply: 100_000e6,
            riskParams: _getRiskParams()
        });
        
        uint256 supplyRate = Core.calculateSupplyRate(supplyInput);
        assertGt(supplyRate, 0.4e27, "Supply rate should be attractive at high utilization");
    }
    
    function test_MarketResolution_TotalLoss() public {
        // Test when prediction market resolves to 0
        Core.CalcThreePoolDistributionInput memory input = Core.CalcThreePoolDistributionInput({
            totalCollateralRedeemed: 0, // Complete loss
            aaveCurrentTotalDebt: 100_000e6,
            accumulatedSpread: 5_000e6,
            currentBorrowIndex: 1.05e27,
            totalScaledBorrowed: 100_000e6,
            totalNotScaledBorrowed: 100_000e6,
            reserveFactor: 1000,
            lpShareOfRedeemed: 5000
        });
        
        Core.ThreePoolDistributionResult memory result = Core.calculateThreePoolDistribution(input);
        
        assertEq(result.aaveDebtRepaid, 0, "No funds to repay Aave");
        assertEq(result.protocolPool, 0, "No funds for protocol");
        assertEq(result.lpSpreadPool, 0, "No funds for LPs");
        assertEq(result.borrowerPool, 0, "No funds for borrowers");
    }
    
    // ============ Helper Functions ============
    
    function _getInitialReserve() internal view returns (Storage.ReserveData memory) {
        return Storage.ReserveData({
            variableBorrowIndex: RAY,
            liquidityIndex: RAY,
            totalScaledBorrowed: 80_000e6, // 80k borrowed
            totalBorrowed: 80_000e6,
            totalScaledSupplied: 100_000e6, // 100k supplied  
            totalCollateral: 150e18, // 150 prediction tokens
            lastUpdateTimestamp: block.timestamp,
            cachedUtilization: 0.8e27,
            accumulatedSpread: 0,
            accumulatedRedeemed: 0,
            accumulatedReserves: 0
        });
    }
    
    function _getRiskParams() internal view returns (Storage.RiskParams memory) {
        return Storage.RiskParams({
            interestRateMode: InterestRateMode.VARIABLE,
            baseSpreadRate: 0.02e27, // 2%
            optimalUtilization: 0.8e27, // 80%
            slope1: 0.04e27, // 4%
            slope2: 0.75e27, // 75%
            reserveFactor: 1000, // 10%
            ltv: 6000, // 60%
            liquidationThreshold: 7500, // 75%
            liquidationCloseFactor: 5000,
            lpShareOfRedeemed: 5000, // 50%
            liquidationBonus: 500, // 5% bonus
            maturityDate: block.timestamp + 90 days,
            priceOracle: address(0x1),
            liquidityLayer: address(0x2),
            supplyAsset: address(0x3),
            collateralAsset: address(0x4),
            supplyAssetDecimals: 6,
            collateralAssetDecimals: 18,
            curator: address(0x5),
            isActive: true
        });
    }
}