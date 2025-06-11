// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/Core.sol";
import "../../src/libraries/Storage.sol";

contract CoreSecurityTest is Test {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    
    uint256 constant RAY = 1e27;
    uint256 constant WAD = 1e18;
    uint256 constant MAX_UINT256 = type(uint256).max;
    
    // ============ Overflow/Underflow Protection Tests ============
    
    function test_OverflowProtection_LargeIndices() public {
        // Test with indices approaching practical limits
        Storage.ReserveData memory reserve = Storage.ReserveData({
            variableBorrowIndex: 10e27, // 10x growth
            liquidityIndex: 10e27,
            totalScaledBorrowed: 1_000_000e6,
            totalBorrowed: 10_000_000e6, // 10x due to index
            totalScaledSupplied: 1_000_000e6,
            totalCollateral: 1000e18,
            lastUpdateTimestamp: block.timestamp,
            cachedUtilization: 0.9e27,
            accumulatedSpread: 0,
            accumulatedRedeemed: 0,
            accumulatedReserves: 0
        });
        
        // Fast forward to accumulate more interest
        vm.warp(block.timestamp + 365 days);
        
        Core.UpdateIndicesInput memory input = Core.UpdateIndicesInput({
            reserve: reserve,
            riskParams: _getHighRateParams()
        });
        
        // Should not overflow even with high indices and rates
        (uint256 newBorrowIndex, uint256 newLiquidityIndex) = Core.updateIndices(input);
        
        assertGt(newBorrowIndex, reserve.variableBorrowIndex, "Borrow index should increase");
        assertLt(newBorrowIndex, 100e27, "Index should remain reasonable");
    }
    
    function test_UnderflowProtection_DebtCalculation() public {
        // Test debt calculation when spread principal could underflow
        Core.CalcUserTotalDebtInput memory input = Core.CalcUserTotalDebtInput({
            principalDebt: 100e6,
            scaledPolynanceSpreadDebtPrincipal: 110e6, // Scaled up
            initialBorrowAmount: 110e6,
            currentPolynanceSpreadBorrowIndex: 0.99e27 // Index decreased (shouldn't happen but test anyway)
        });
        
        (uint256 totalDebt, uint256 principal, uint256 spreadInterest) = Core.calculateUserTotalDebt(input);
        
        // Should handle gracefully without underflow
        assertEq(spreadInterest, 0, "Spread interest should be 0 when negative");
        assertEq(totalDebt, principal, "Total debt should equal principal when no positive spread");
    }
    
    // ============ Manipulation Resistance Tests ============
    
    function test_ManipulationResistance_UtilizationSpike() public {
        // Test rate stability under sudden utilization changes
        Storage.RiskParams memory params = _getRiskParams();
        
        // Calculate rate at 50% utilization
        Core.CalcPureSpreadRateInput memory input50 = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: 50_000e6,
            totalPolynanceSupply: 100_000e6,
            riskParams: params
        });
        uint256 rate50 = Core.calculateSpreadRate(input50);
        
        // Calculate rate at 95% utilization (flash loan attack scenario)
        Core.CalcPureSpreadRateInput memory input95 = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: 95_000e6,
            totalPolynanceSupply: 100_000e6,
            riskParams: params
        });
        uint256 rate95 = Core.calculateSpreadRate(input95);
        
        // Rates should increase but within reasonable bounds
        assertGt(rate95, rate50, "Higher utilization should increase rate");
        assertLt(rate95, rate50 * 10, "Rate increase should be bounded");
    }
    
    // ============ Precision Loss Tests ============
    
    function test_PrecisionLoss_SmallAmounts() public {
        // Test with amounts that could cause precision loss
        uint256 dustAmount = 1; // 1 wei of USDC (0.000001 USDC)
        uint256 largeIndex = 2e27; // 2x multiplier
        
        // Test scaling down and up
        uint256 scaled = Core.calculateScaledValue(dustAmount, largeIndex);
        uint256 unscaled = scaled.rayMul(largeIndex);
        
        // Some precision loss is acceptable for dust amounts
        assertLe(unscaled, dustAmount * 2, "Precision loss should be bounded");
    }
    
    function test_PrecisionLoss_RayOperations() public {
        // Test ray math precision with edge values
        uint256 almostOne = RAY - 1;
        uint256 justOverOne = RAY + 1;
        
        // Test multiplication precision
        uint256 result1 = almostOne.rayMul(almostOne);
        uint256 result2 = justOverOne.rayMul(justOverOne);
        
        assertLt(result1, RAY, "Almost one squared should be less than one");
        assertGt(result2, RAY, "Just over one squared should be greater than one");
    }
    
    // ============ Market Resolution Edge Cases ============
    
    function test_MarketResolution_RoundingFairness() public {
        // Test that rounding doesn't favor any party unfairly
        Core.CalcThreePoolDistributionInput memory input = Core.CalcThreePoolDistributionInput({
            totalCollateralRedeemed: 100_000e6 + 1, // Add 1 wei to test rounding
            aaveCurrentTotalDebt: 80_000e6,
            accumulatedSpread: 5_000e6,
            currentBorrowIndex: 1.04e27,
            totalScaledBorrowed: 80_000e6,
            totalNotScaledBorrowed: 80_000e6,
            reserveFactor: 1500, // 15% - odd number to test rounding
            lpShareOfRedeemed: 3333 // 33.33% - tests rounding
        });
        
        Core.ThreePoolDistributionResult memory result = Core.calculateThreePoolDistribution(input);
        
        // Verify all funds are distributed (no dust left)
        uint256 totalDistributed = result.aaveDebtRepaid + result.protocolPool + 
                                  result.lpSpreadPool + result.borrowerPool;
        
        // Allow for maximum 1 wei rounding error
        assertApproxEqAbs(totalDistributed, input.totalCollateralRedeemed, 1, 
                         "All funds should be distributed with minimal rounding");
    }
    
    function test_MarketResolution_ZeroCollateral() public {
        // Test with markets that have no collateral
        Core.CalcBorrowerClaimInput memory input = Core.CalcBorrowerClaimInput({
            positionCollateralAmount: 100e18,
            totalCollateral: 0, // Edge case: no total collateral
            borrowerPool: 10_000e6
        });
        
        uint256 claim = Core.calculateBorrowerClaimAmount(input);
        assertEq(claim, 0, "Should return 0 when total collateral is 0");
    }
    
    // ============ Validation Tests ============
    
    function test_ValidateBorrow_Boundaries() public {
        // Test borrow validation at boundaries
        uint256 totalSupply = 100_000e6;
        uint256 currentBorrowed = 60_000e6;
        uint256 userMaxBorrow = 40_000e6;
        
        // Test exact boundary
        bool valid = Core.validateBorrow(
            currentBorrowed + userMaxBorrow,
            totalSupply,
            userMaxBorrow,
            userMaxBorrow
        );
        assertTrue(valid, "Should allow borrowing at exact limit");
        
        // Test over user limit
        valid = Core.validateBorrow(
            currentBorrowed + userMaxBorrow + 1,
            totalSupply,
            userMaxBorrow + 1,
            userMaxBorrow
        );
        assertFalse(valid, "Should reject borrowing over user limit");
        
        // Test over pool limit
        valid = Core.validateBorrow(
            totalSupply + 1,
            totalSupply,
            1,
            userMaxBorrow
        );
        assertFalse(valid, "Should reject borrowing over pool limit");
    }
    
    // ============ Interest Accumulation Attack Vectors ============
    
    function test_InterestAccumulation_TimeManipulation() public {
        // Test that interest accumulation is resilient to time manipulation
        Storage.ReserveData memory reserve = _getInitialReserve();
        Storage.RiskParams memory params = _getRiskParams();
        
        // Normal 1 day accumulation
        vm.warp(block.timestamp + 1 days);
        Core.UpdateIndicesInput memory input1 = Core.UpdateIndicesInput({
            reserve: reserve,
            riskParams: params
        });
        (uint256 index1Day, ) = Core.updateIndices(input1);
        
        // Reset and do 24 1-hour updates
        reserve = _getInitialReserve();
        uint256 currentIndex = reserve.variableBorrowIndex;
        
        for (uint i = 0; i < 24; i++) {
            vm.warp(reserve.lastUpdateTimestamp + 1 hours);
            Core.UpdateIndicesInput memory inputHourly = Core.UpdateIndicesInput({
                reserve: reserve,
                riskParams: params
            });
            (currentIndex, ) = Core.updateIndices(inputHourly);
            reserve.variableBorrowIndex = currentIndex;
            reserve.lastUpdateTimestamp = block.timestamp;
        }
        
        // Results should be very close (compound interest difference)
        assertApproxEqRel(currentIndex, index1Day, 0.001e18, 
                         "Frequent updates shouldn't significantly change interest");
    }
    
    // ============ Helper Functions ============
    
    function _getInitialReserve() internal view returns (Storage.ReserveData memory) {
        return Storage.ReserveData({
            variableBorrowIndex: RAY,
            liquidityIndex: RAY,
            totalScaledBorrowed: 80_000e6,
            totalBorrowed: 80_000e6,
            totalScaledSupplied: 100_000e6,
            totalCollateral: 100e18,
            lastUpdateTimestamp: block.timestamp,
            cachedUtilization: 0.8e27,
            accumulatedSpread: 0,
            accumulatedRedeemed: 0,
            accumulatedReserves: 0
        });
    }

        
    function _getHighRateParams() internal view returns (Storage.RiskParams memory) {
        Storage.RiskParams memory params = _getRiskParams();
        params.baseSpreadRate = 0.1e27; // 10% base
        params.slope1 = 0.15e27; // 15% slope1
        params.slope2 = 2e27; // 200% slope2
        return params;
    }
    
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
            liquidationBonus: 500,
            lpShareOfRedeemed: 5000,
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

}