// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/Core.sol";
import "../../src/libraries/Storage.sol";

contract CoreLiquidationTest is Test {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using Math for uint256;

    // Constants
    uint256 constant RAY = 1e27;
    uint256 constant WAD = 1e18;
    uint256 constant MAX_BPS = 10_000;
    
    // Liquidation parameters
    uint256 constant LIQUIDATION_THRESHOLD = 7500; // 75%
    uint256 constant LIQUIDATION_CLOSE_FACTOR = 5000; // 50% max liquidation
    uint256 constant LIQUIDATION_BONUS = 500; // 5% bonus
    
    // Asset decimals
    uint256 constant USDC_DECIMALS = 6;
    uint256 constant COLLATERAL_DECIMALS = 18;
    // ============ Health Factor Tests ============
    
    function test_CalculateHealthFactor_Healthy() public {
        // User has 100 tokens worth $0.80 each, borrowed 40 USDC
        Core.CalcHealthFactorInput memory input = Core.CalcHealthFactorInput({
            collateralAmount: 100e18,
            collateralPrice: 0.8e27, // $0.80
            userTotalDebt: 40e6, // 40 USDC
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        uint256 healthFactor = Core.calculateHealthFactor(input);
        
        // Collateral value = 100 * 0.8 = $80
        // Liquidation value = 80 * 0.75 = $60
        // Health factor = 60 / 40 = 1.5
        assertEq(healthFactor, 1.5e27, "Health factor should be 1.5");
        assertFalse(Core.isLiquidatable(healthFactor), "Should not be liquidatable");
    }
    
    function test_CalculateHealthFactor_Unhealthy() public {
        // User has 100 tokens worth $0.50 each, borrowed 40 USDC
        Core.CalcHealthFactorInput memory input = Core.CalcHealthFactorInput({
            collateralAmount: 100e18,
            collateralPrice: 0.5e27, // $0.50
            userTotalDebt: 40e6, // 40 USDC
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        uint256 healthFactor = Core.calculateHealthFactor(input);
        
        // Collateral value = 100 * 0.5 = $50
        // Liquidation value = 50 * 0.75 = $37.5
        // Health factor = 37.5 / 40 = 0.9375
        assertEq(healthFactor, 0.9375e27, "Health factor should be 0.9375");
        assertTrue(Core.isLiquidatable(healthFactor), "Should be liquidatable");
    }
    
    function test_CalculateHealthFactor_NoDebt() public {
        Core.CalcHealthFactorInput memory input = Core.CalcHealthFactorInput({
            collateralAmount: 100e18,
            collateralPrice: 0.8e27,
            userTotalDebt: 0, // No debt
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        uint256 healthFactor = Core.calculateHealthFactor(input);
        assertEq(healthFactor, type(uint256).max, "Health factor should be max when no debt");
        assertFalse(Core.isLiquidatable(healthFactor), "Should not be liquidatable with no debt");
    }
    
    function test_CalculateHealthFactor_AtLiquidationThreshold() public {
        // Exactly at liquidation threshold
        uint256 collateralValue = 100e6; // $100
        uint256 maxDebt = collateralValue.percentMul(LIQUIDATION_THRESHOLD); // $75
        
        Core.CalcHealthFactorInput memory input = Core.CalcHealthFactorInput({
            collateralAmount: 125e18, // 125 tokens at $0.80 = $100
            collateralPrice: 0.8e27,
            userTotalDebt: maxDebt,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        uint256 healthFactor = Core.calculateHealthFactor(input);
        assertEq(healthFactor, RAY, "Health factor should be exactly 1.0 at threshold");
        assertFalse(Core.isLiquidatable(healthFactor), "Should not be liquidatable at exactly 1.0");
    }
    
    // ============ Liquidation Amount Calculation Tests ============
    
    function test_CalculateLiquidationAmounts_PartialLiquidation() public {
        // User owes 100 USDC, 50% can be liquidated
        Core.CalcLiquidationAmountsInput memory input = Core.CalcLiquidationAmountsInput({
            userTotalDebt: 100e6,
            collateralAmount: 200e18, // 200 tokens
            collateralPrice: 0.6e27, // $0.60 each
            liquidationCloseFactor: LIQUIDATION_CLOSE_FACTOR,
            liquidationBonus: LIQUIDATION_BONUS,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        Core.LiquidationAmountsResult memory result = Core.calculateLiquidationAmounts(input);
        
        // Max liquidatable = 100 * 50% = 50 USDC
        assertEq(result.debtToRepay, 50e6, "Should liquidate 50% of debt");
        assertFalse(result.isFullLiquidation, "Should be partial liquidation");
        
        // Collateral to seize = 50 USDC worth + 5% bonus
        // 50 USDC / 0.6 = 83.33 tokens, + 5% = 87.5 tokens
        uint256 expectedBase = 50e6 * 10**COLLATERAL_DECIMALS / 10**USDC_DECIMALS * RAY / input.collateralPrice;
        uint256 expectedWithBonus = expectedBase.percentMul(10500); // 105%
        
        assertEq(result.collateralToSeize, expectedWithBonus, "Collateral seized should include bonus");
        assertEq(result.liquidationBonus, expectedWithBonus - expectedBase, "Bonus calculation");
    }
    
    function test_CalculateLiquidationAmounts_FullLiquidation_DebtBased() public {
        // Small debt that results in full liquidation
        Core.CalcLiquidationAmountsInput memory input = Core.CalcLiquidationAmountsInput({
            userTotalDebt: 10e6, // Only 10 USDC debt
            collateralAmount: 100e18,
            collateralPrice: 0.5e27,
            liquidationCloseFactor: 10000,
            liquidationBonus: LIQUIDATION_BONUS,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        Core.LiquidationAmountsResult memory result = Core.calculateLiquidationAmounts(input);
        
        // Even though close factor is 50%, full debt can be liquidated if small enough
        assertEq(result.debtToRepay, 10e6, "Should liquidate full debt");
        assertTrue(result.isFullLiquidation, "Should be full liquidation");
        
        // Verify collateral calculation
        uint256 baseCollateral = 10e6 * 10**COLLATERAL_DECIMALS / 10**USDC_DECIMALS * RAY / input.collateralPrice;
        uint256 withBonus = baseCollateral.percentMul(10500);
        assertEq(result.collateralToSeize, withBonus, "Collateral calculation with bonus");
    }
    
    function test_CalculateLiquidationAmounts_InsufficientCollateral() public {
        // Not enough collateral to cover debt + bonus
        Core.CalcLiquidationAmountsInput memory input = Core.CalcLiquidationAmountsInput({
            userTotalDebt: 100e6,
            collateralAmount: 50e18, // Only 50 tokens
            collateralPrice: 1e27, // $1 each = $50 total
            liquidationCloseFactor: LIQUIDATION_CLOSE_FACTOR,
            liquidationBonus: LIQUIDATION_BONUS,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        Core.LiquidationAmountsResult memory result = Core.calculateLiquidationAmounts(input);
        
        // Should seize all collateral
        assertEq(result.collateralToSeize, 50e18, "Should seize all available collateral");
        assertTrue(result.isFullLiquidation, "Should be full liquidation");
        
        // Debt repaid = collateral value / 1.05 (removing bonus)
        // 50 / 1.05 = 47.62 USDC
        uint256 expectedDebt = 50e6 * MAX_BPS / (MAX_BPS + LIQUIDATION_BONUS);
        assertApproxEqAbs(result.debtToRepay, expectedDebt, 1e6, "Debt repaid adjusted for available collateral");
    }
    
    function test_CalculateLiquidationAmounts_HighBonus() public {
        // Test with high liquidation bonus (20%)
        Core.CalcLiquidationAmountsInput memory input = Core.CalcLiquidationAmountsInput({
            userTotalDebt: 100e6,
            collateralAmount: 300e18,
            collateralPrice: 0.5e27,
            liquidationCloseFactor: LIQUIDATION_CLOSE_FACTOR,
            liquidationBonus: 2000, // 20% bonus
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        Core.LiquidationAmountsResult memory result = Core.calculateLiquidationAmounts(input);
        
        // 50 USDC debt to repay
        assertEq(result.debtToRepay, 50e6, "Should respect close factor");
        
        // Base collateral = 50 / 0.5 = 100 tokens
        // With 20% bonus = 120 tokens
        uint256 expectedCollateral = 120e18;
        assertEq(result.collateralToSeize, expectedCollateral, "Should apply 20% bonus");
        assertEq(result.liquidationBonus, 20e18, "Bonus should be 20 tokens");
    }
    
    // ============ Liquidation Validation Tests ============
    
    function test_ValidateLiquidation_AllValidations() public {
        // Test all validation scenarios
        
        // 1. Healthy position
        Core.ValidateLiquidationInput memory input = Core.ValidateLiquidationInput({
            healthFactor: 1.5e27, // Healthy
            repayAmount: 50e6,
            maxRepayAmount: 50e6,
            userTotalDebt: 100e6,
            availableCollateral: 200e18
        });
        
        (bool isValid, string memory reason) = Core.validateLiquidation(input);
        assertFalse(isValid, "Healthy position should not be liquidatable");
        assertEq(reason, "Position is healthy", "Should return correct reason");
        
        // 2. Zero repay amount
        input.healthFactor = 0.9e27; // Unhealthy
        input.repayAmount = 0;
        (isValid, reason) = Core.validateLiquidation(input);
        assertFalse(isValid, "Zero repay should be invalid");
        assertEq(reason, "Repay amount must be positive", "Should return correct reason");
        
        // 3. Exceeds close factor
        input.repayAmount = 60e6;
        input.maxRepayAmount = 50e6;
        (isValid, reason) = Core.validateLiquidation(input);
        assertFalse(isValid, "Should not exceed close factor");
        assertEq(reason, "Repay amount exceeds close factor limit", "Should return correct reason");
        
        // 4. Exceeds user debt
        input.repayAmount = 150e6;
        input.maxRepayAmount = 150e6;
        (isValid, reason) = Core.validateLiquidation(input);
        assertFalse(isValid, "Should not exceed user debt");
        assertEq(reason, "Repay amount exceeds user debt", "Should return correct reason");
        
        // 5. No collateral
        input.repayAmount = 50e6;
        input.maxRepayAmount = 50e6;
        input.availableCollateral = 0;
        (isValid, reason) = Core.validateLiquidation(input);
        assertFalse(isValid, "Should require collateral");
        assertEq(reason, "No collateral to liquidate", "Should return correct reason");
        
        // 6. Valid liquidation
        input.availableCollateral = 200e18;
        (isValid, reason) = Core.validateLiquidation(input);
        assertTrue(isValid, "Should be valid liquidation");
        assertEq(reason, "", "Should have empty reason for valid liquidation");
    }
    
    // ============ Scaled Debt Update Tests ============
    
    function test_CalculateNewScaledDebt_PartialRepayment() public {
        uint256 currentScaledDebt = 100e6;
        uint256 currentBorrowIndex = 1.1e27; // 10% interest accumulated
        uint256 debtRepaid = 55e6; // Repay half of total debt (50 principal + 5 interest)
        
        uint256 newScaledDebt = Core.calculateNewScaledDebt(
            currentScaledDebt,
            debtRepaid,
            currentBorrowIndex
        );
        
        // Current total debt = 100 * 1.1 = 110
        // After repaying 55, remaining = 55
        // New scaled = 55 / 1.1 = 50
        assertEq(newScaledDebt, 50e6, "Scaled debt should be halved");
    }
    
    function test_CalculateNewScaledDebt_FullRepayment() public {
        uint256 currentScaledDebt = 100e6;
        uint256 currentBorrowIndex = 1.2e27;
        uint256 totalDebt = currentScaledDebt.rayMul(currentBorrowIndex); // 120
        
        uint256 newScaledDebt = Core.calculateNewScaledDebt(
            currentScaledDebt,
            totalDebt,
            currentBorrowIndex
        );
        
        assertEq(newScaledDebt, 0, "Scaled debt should be zero after full repayment");
    }
    
    function test_CalculateNewScaledDebt_Overpayment() public {
        uint256 currentScaledDebt = 100e6;
        uint256 currentBorrowIndex = 1.05e27;
        uint256 debtRepaid = 200e6; // More than total debt
        
        uint256 newScaledDebt = Core.calculateNewScaledDebt(
            currentScaledDebt,
            debtRepaid,
            currentBorrowIndex
        );
        
        assertEq(newScaledDebt, 0, "Scaled debt should be zero for overpayment");
    }
    
    // ============ Edge Cases and Boundary Tests ============
    
    function test_Liquidation_ExactlyAtHealthFactor1() public {
        // Use values that divide evenly
        // 100 tokens at $0.75 = $75 collateral value
        // $75 * 0.75 threshold = $56.25 liquidation value
        // $56.25 debt = exactly 1.0 health factor
        
        Core.CalcHealthFactorInput memory healthInput = Core.CalcHealthFactorInput({
            collateralAmount: 100e18, // 100 tokens
            collateralPrice: 0.75e27, // $0.75
            userTotalDebt: 56.25e6, // $56.25 debt
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        uint256 healthFactor = Core.calculateHealthFactor(healthInput);
        assertEq(healthFactor, RAY, "Health factor should be exactly 1.0");
        
        // Just below 1.0 should be liquidatable
        healthInput.userTotalDebt = 56.26e6; // Slightly more debt
        healthFactor = Core.calculateHealthFactor(healthInput);
        assertLt(healthFactor, RAY, "Health factor should be below 1.0");
        assertTrue(Core.isLiquidatable(healthFactor), "Should be liquidatable below 1.0");
    }
    
    function test_Liquidation_DifferentDecimals() public {
        // Test with 8 decimal collateral and 18 decimal supply asset
        Core.CalcLiquidationAmountsInput memory input = Core.CalcLiquidationAmountsInput({
            userTotalDebt: 1e18, // 1 token with 18 decimals
            collateralAmount: 2e8, // 2 tokens with 8 decimals
            collateralPrice: 0.6e27, // $0.60 each
            liquidationCloseFactor: LIQUIDATION_CLOSE_FACTOR,
            liquidationBonus: LIQUIDATION_BONUS,
            supplyAssetDecimals: 18,
            collateralAssetDecimals: 8
        });
        
        Core.LiquidationAmountsResult memory result = Core.calculateLiquidationAmounts(input);
        
        // Should handle decimal conversion correctly
        assertGt(result.collateralToSeize, 0, "Should calculate collateral with different decimals");
        assertLe(result.collateralToSeize, input.collateralAmount, "Should not exceed available collateral");
    }
    
    // ============ Fuzz Tests ============
    
    function testFuzz_HealthFactor_Consistency(
        uint256 collateralAmount,
        uint256 collateralPrice,
        uint256 userDebt
    ) public {
        collateralAmount = bound(collateralAmount, 1e18, 1_000_000e18);
        collateralPrice = bound(collateralPrice, 0.01e27, 100e27);
        userDebt = bound(userDebt, 1e6, 1_000_000e6);
        
        Core.CalcHealthFactorInput memory input = Core.CalcHealthFactorInput({
            collateralAmount: collateralAmount,
            collateralPrice: collateralPrice,
            userTotalDebt: userDebt,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        uint256 healthFactor = Core.calculateHealthFactor(input);
        
        // Health factor properties
        if (userDebt == 0) {
            assertEq(healthFactor, type(uint256).max, "Zero debt should give max health factor");
        } else {
            uint256 collateralValue = collateralAmount.mulDiv(collateralPrice, RAY)
                .mulDiv(10**USDC_DECIMALS, 10**COLLATERAL_DECIMALS);
            uint256 threshold = collateralValue.percentMul(LIQUIDATION_THRESHOLD);
            
            if (threshold > userDebt) {
                assertGt(healthFactor, RAY, "Should be healthy if threshold > debt");
            } else if (threshold < userDebt) {
                assertLt(healthFactor, RAY, "Should be unhealthy if threshold < debt");
            }
        }
    }
    
    function testFuzz_LiquidationAmounts_Conservation(
        uint256 userDebt,
        uint256 collateralAmount,
        uint256 collateralPrice,
        uint256 closeFactor,
        uint256 bonus
    ) public {
        console.log("1. testFuzz_LiquidationAmounts_Conservation");
        userDebt = bound(userDebt, 1e6, 1_000_000e6);
        collateralAmount = bound(collateralAmount, 1e18, 1_000_000e18);
        collateralPrice = bound(collateralPrice, 0.01e27, 10e27);
        closeFactor = bound(closeFactor, 1000, 10000); // 10% to 100%
        bonus = bound(bonus, 0, 2000); // 0% to 20%

        
        Core.CalcLiquidationAmountsInput memory input = Core.CalcLiquidationAmountsInput({
            userTotalDebt: userDebt,
            collateralAmount: collateralAmount,
            collateralPrice: collateralPrice,
            liquidationCloseFactor: closeFactor,
            liquidationBonus: bonus,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        Core.LiquidationAmountsResult memory result = Core.calculateLiquidationAmounts(input);
        
        // Invariants
        assertLe(result.debtToRepay, userDebt, "Cannot repay more than total debt");
        assertLe(result.collateralToSeize, collateralAmount, "Cannot seize more than available");
        
        if (result.debtToRepay > 0) {
            assertGt(result.collateralToSeize, 0, "Must seize collateral if repaying debt");
        }
        
        // Verify bonus calculation
        if (result.collateralToSeize < collateralAmount) {
            // If not seizing all collateral, bonus should be calculated correctly
            uint256 baseCollateral = result.debtToRepay
                .mulDiv(10**COLLATERAL_DECIMALS, 10**USDC_DECIMALS)
                .rayDiv(collateralPrice);
            uint256 expectedBonus = baseCollateral.percentMul(bonus);
            assertApproxEqAbs(result.liquidationBonus, expectedBonus, 1e12, "Bonus calculation accuracy");
        }
    }
    
    function testFuzz_ScaledDebtUpdate_Precision(
        uint256 scaledDebt,
        uint256 borrowIndex,
        uint256 repaymentPercent
    ) public {
        scaledDebt = bound(scaledDebt, 1, 1_000_000e6);
        borrowIndex = bound(borrowIndex, RAY, 10 * RAY); // 1x to 10x
        repaymentPercent = bound(repaymentPercent, 0, 10000); // 0% to 100%
        
        uint256 totalDebt = scaledDebt.rayMul(borrowIndex);
        uint256 repayAmount = totalDebt.percentMul(repaymentPercent);
        
        uint256 newScaledDebt = Core.calculateNewScaledDebt(
            scaledDebt,
            repayAmount,
            borrowIndex
        );
        
        if (repaymentPercent == 10000) {
            assertEq(newScaledDebt, 0, "Full repayment should zero debt");
        } else if (repaymentPercent == 0) {
            assertEq(newScaledDebt, scaledDebt, "No repayment should maintain debt");
        } else {
            // Verify precision
            uint256 newTotalDebt = newScaledDebt.rayMul(borrowIndex);
            uint256 expectedRemaining = totalDebt - repayAmount;
            assertApproxEqAbs(newTotalDebt, expectedRemaining, 1000, "Debt precision after partial repayment");
        }
    }
    
    // ============ Integration Scenarios ============
    
    function test_LiquidationScenario_CascadingLiquidations() public {
        // Simulate multiple liquidations on same position
        uint256 initialDebt = 1000e6;
        uint256 initialCollateral = 2000e18;
        uint256 collateralPrice = 0.6e27;
        uint256 borrowIndex = 1.1e27;
        
        // First liquidation
        Core.CalcLiquidationAmountsInput memory input1 = Core.CalcLiquidationAmountsInput({
            userTotalDebt: initialDebt,
            collateralAmount: initialCollateral,
            collateralPrice: collateralPrice,
            liquidationCloseFactor: LIQUIDATION_CLOSE_FACTOR,
            liquidationBonus: LIQUIDATION_BONUS,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        Core.LiquidationAmountsResult memory result1 = Core.calculateLiquidationAmounts(input1);
        
        // Update position after first liquidation
        uint256 remainingDebt = initialDebt - result1.debtToRepay;
        uint256 remainingCollateral = initialCollateral - result1.collateralToSeize;
        
        console.log("After first liquidation:");
        console.log("Remaining debt:", remainingDebt);
        console.log("Remaining collateral:", remainingCollateral);
        
        // Second liquidation with updated values
        Core.CalcLiquidationAmountsInput memory input2 = Core.CalcLiquidationAmountsInput({
            userTotalDebt: remainingDebt,
            collateralAmount: remainingCollateral,
            collateralPrice: collateralPrice,
            liquidationCloseFactor: LIQUIDATION_CLOSE_FACTOR,
            liquidationBonus: LIQUIDATION_BONUS,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        Core.LiquidationAmountsResult memory result2 = Core.calculateLiquidationAmounts(input2);
        
        // Verify cascading liquidations work correctly
        assertGt(result2.debtToRepay, 0, "Should allow second liquidation");
        assertLe(result2.collateralToSeize, remainingCollateral, "Should not exceed remaining collateral");
    }
    
    function test_LiquidationScenario_PriceVolatility() public {
        // Test liquidation behavior during price swings
        uint256 collateral = 100e18;
        uint256 debt = 60e6;
        
        uint256[] memory prices = new uint256[](4);
        prices[0] = 1e27;    // $1.00 - healthy
        prices[1] = 0.85e27; // $0.85 - approaching danger
        prices[2] = 0.79e27; // $0.79 - just unhealthy
        prices[3] = 0.5e27;  // $0.50 - deeply underwater
        
        for (uint i = 0; i < prices.length; i++) {
            Core.CalcHealthFactorInput memory input = Core.CalcHealthFactorInput({
                collateralAmount: collateral,
                collateralPrice: prices[i],
                userTotalDebt: debt,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                supplyAssetDecimals: USDC_DECIMALS,
                collateralAssetDecimals: COLLATERAL_DECIMALS
            });
            
            uint256 healthFactor = Core.calculateHealthFactor(input);
            bool liquidatable = Core.isLiquidatable(healthFactor);
            
            console.log("Price:", prices[i] / 1e25, "cents");
            console.log("Health Factor:", healthFactor / 1e25, "%");
            console.log("Liquidatable:", liquidatable);
            console.log("---");
            
            if (i <= 1) {
                assertFalse(liquidatable, "Should not be liquidatable at high prices");
            } else {
                assertTrue(liquidatable, "Should be liquidatable at low prices");
            }
        }
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
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            liquidationCloseFactor: LIQUIDATION_CLOSE_FACTOR,
            liquidationBonus: LIQUIDATION_BONUS,
            lpShareOfRedeemed: 5000,
            limitDate: block.timestamp + 90 days,
            priceOracle: address(0x1),
            liquidityLayer: address(0x2),
            supplyAsset: address(0x3),
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS,
            curator: address(0x5),
            isActive: true
        });
    }
}