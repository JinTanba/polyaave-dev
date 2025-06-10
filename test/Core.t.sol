// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {Storage, InterestRateMode} from "../src/libraries/Storage.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/protocol/libraries/math/PercentageMath.sol";
import {MathUtils} from "@aave/protocol/libraries/math/MathUtils.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";

contract CoreTest is Test {
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    // Constants
    uint256 private constant RAY = 1e27;
    uint256 private constant WAD = 1e18;
    uint256 private constant PERCENTAGE_FACTOR = 1e4;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    
    // Realistic lending protocol parameters
    uint256 private constant BASE_SPREAD_RATE = 0.02e27; // 2% base rate
    uint256 private constant SLOPE1 = 0.04e27; // 4%
    uint256 private constant SLOPE2 = 1e27; // 100%
    uint256 private constant OPTIMAL_UTILIZATION = 0.8e27; // 80%
    uint256 private constant LTV = 7500; // 75%
    uint256 private constant LIQUIDATION_THRESHOLD = 8500; // 85%
    
    // Test variables
    Storage.RiskParams riskParams;
    Storage.ReserveData reserveData;
    
    function setUp() public {
        // Initialize risk parameters with realistic values
        riskParams = Storage.RiskParams({
            interestRateMode: InterestRateMode.VARIABLE,
            baseSpreadRate: BASE_SPREAD_RATE,
            slope1: SLOPE1,
            slope2: SLOPE2,
            optimalUtilization: OPTIMAL_UTILIZATION,
            reserveFactor: 1000, // 10%
            ltv: LTV,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            maturityDate: block.timestamp + 30 days,
            priceOracle: address(0x1), // Mock address
            aaveModule: address(0x2), // Mock address
            supplyAsset: address(0x3), // Mock USDC
            collateralAsset: address(0x4), // Mock prediction token
            supplyAssetDecimals: 18,
            collateralAssetDecimals: 18,
            curator: address(this),
            isActive: true,
            lpShareOfRedeemed: 200
        });

        
        // Initialize reserve data
        reserveData = Storage.ReserveData({
            liquidityIndex: RAY, // Start at 1 (RAY)
            variableBorrowIndex: RAY, // Start at 1 (RAY)
            lastUpdateTimestamp: block.timestamp,
            totalSupplied: 0,
            totalBorrowed: 0,
            accumulatedSpread: 0,
            totalCollateral: 0,
            cachedUtilization: 0,
            accumulatedRedeemed: 0,
            accumulatedReserves: 0
        });
    }
    
    // Test: Calculate Utilization
    function test_calculateUtilization() public {
        // Test case 1: 50% utilization
        uint256 totalBorrowed = 50e18;
        uint256 totalSupply = 100e18;
        uint256 utilization = Core.calculateUtilization(totalBorrowed, totalSupply);
        assertEq(utilization, 0.5e27, "Utilization should be 50%");
        
        // Test case 2: 0% utilization
        utilization = Core.calculateUtilization(0, totalSupply);
        assertEq(utilization, 0, "Utilization should be 0%");
        
        // Test case 3: 100% utilization
        utilization = Core.calculateUtilization(totalSupply, totalSupply);
        assertEq(utilization, RAY, "Utilization should be 100%");
        
        // Test case 4: Zero supply
        utilization = Core.calculateUtilization(totalBorrowed, 0);
        assertEq(utilization, 0, "Utilization should be 0 when supply is 0");
    }
    
    // Test: Calculate Spread Rate
    function test_calculateSpreadRate() public {
        Core.CalcPureSpreadRateInput memory input;
        
        // Test case 1: Below optimal utilization (50%)
        input = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: 50e18,
            totalPolynanceSupply: 100e18,
            riskParams: riskParams
        });
        uint256 spreadRate = Core.calculateSpreadRate(input);
        // Expected: baseRate + slope1 * utilization = 2% + 4% * 0.5 = 4%
        assertEq(spreadRate, BASE_SPREAD_RATE + SLOPE1.rayMul(0.5e27), "Spread rate at 50% utilization");
        
        // Test case 2: At optimal utilization (80%)
        input.totalBorrowedPrincipal = 80e18;
        spreadRate = Core.calculateSpreadRate(input);
        // Expected: baseRate + slope1 * 0.8 = 2% + 4% * 0.8 = 5.2%
        assertEq(spreadRate, BASE_SPREAD_RATE + SLOPE1.rayMul(OPTIMAL_UTILIZATION), "Spread rate at optimal utilization");
        
        // Test case 3: Above optimal utilization (90%)
        input.totalBorrowedPrincipal = 90e18;
        spreadRate = Core.calculateSpreadRate(input);
        // Expected: baseRate + slope1 * 0.8 + slope2 * 0.1 = 2% + 3.2% + 10% = 15.2%
        uint256 expectedRate = BASE_SPREAD_RATE + SLOPE1.rayMul(OPTIMAL_UTILIZATION) + SLOPE2.rayMul(0.1e27);
        assertEq(spreadRate, expectedRate, "Spread rate at 90% utilization");
    }
    
    // Test: Calculate Supply Rate (Original test for gross rate)
    function test_calculateSupplyRate_gross() public {
        Core.CalcSupplyRateInput memory input;
        
        // Test case 1: 50% utilization
        input = Core.CalcSupplyRateInput({
            totalBorrowedPrincipal: 50e18,
            totalPolynanceSupply: 100e18,
            riskParams: riskParams
        });
        uint256 actualGrossSupplyRate = Core.calculateSupplyRate(input); // Core.calculateSupplyRate now returns gross
        
        // Calculate expected gross supply rate
        uint256 spreadRate = Core.calculateSpreadRate(Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: input.totalBorrowedPrincipal,
            totalPolynanceSupply: input.totalPolynanceSupply,
            riskParams: input.riskParams
        }));
        uint256 utilization = Core.calculateUtilization(input.totalBorrowedPrincipal, input.totalPolynanceSupply);
        uint256 expectedGrossSupplyRate = spreadRate.rayMul(utilization);
        assertEq(actualGrossSupplyRate, expectedGrossSupplyRate, "Supply rate should be gross at 50% utilization");
        
        // Test case 2: 0% utilization
        input.totalBorrowedPrincipal = 0;
        uint256 actualGrossSupplyRateAtZeroUtil = Core.calculateSupplyRate(input);
        assertEq(actualGrossSupplyRateAtZeroUtil, 0, "Gross supply rate should be 0 at 0% utilization");
    }

    // Test: Calculate Supply Rate with Reserve Factor (Net Rate for LPs)
    // This test is commented out because Core.calculateSupplyRate now returns GROSS rate as per user request.
    // If reserve factor application is moved elsewhere or re-introduced, this test might need to be updated or un-commented.
    // function test_calculateSupplyRate_withReserveFactor() public {
    //     Core.CalcSupplyRateInput memory input;
    //     uint256 expectedNetSupplyRate;

    //     // Scenario 1: Moderate Utilization, Non-Zero Reserve Factor (10%)
    //     input = Core.CalcSupplyRateInput({
    //         totalBorrowedPrincipal: 50e18,
    //         totalPolynanceSupply: 100e18,
    //         riskParams: riskParams // riskParams.reserveFactor is 1000 (10%)
    //     });
    //     uint256 utilization1 = Core.calculateUtilization(input.totalBorrowedPrincipal, input.totalPolynanceSupply);
    //     uint256 pureSpreadRate1 = Core.calculateSpreadRate(Core.CalcPureSpreadRateInput({
    //         totalBorrowedPrincipal: input.totalBorrowedPrincipal,
    //         totalPolynanceSupply: input.totalPolynanceSupply,
    //         riskParams: input.riskParams
    //     }));
    //     uint256 grossSupplyRate1 = pureSpreadRate1.rayMul(utilization1);
    //     expectedNetSupplyRate = OZMath.mulDiv(grossSupplyRate1, (PERCENTAGE_FACTOR - riskParams.reserveFactor), PERCENTAGE_FACTOR);
    //     // Assuming Core.calculateSupplyRate returns NET rate:
    //     assertEq(Core.calculateSupplyRate(input), expectedNetSupplyRate, "Net supply rate (10% reserve factor, 50% util)");

    //     // Scenario 2: Zero Reserve Factor
    //     Storage.RiskParams memory riskParamsZeroReserve = riskParams;
    //     riskParamsZeroReserve.reserveFactor = 0;
    //     input.riskParams = riskParamsZeroReserve;
    //     uint256 pureSpreadRate2 = Core.calculateSpreadRate(Core.CalcPureSpreadRateInput({
    //         totalBorrowedPrincipal: input.totalBorrowedPrincipal,
    //         totalPolynanceSupply: input.totalPolynanceSupply,
    //         riskParams: input.riskParams
    //     }));
    //     uint256 grossSupplyRate2 = pureSpreadRate2.rayMul(utilization1); // utilization is the same
    //     expectedNetSupplyRate = grossSupplyRate2; // Since reserveFactor is 0
    //     assertEq(Core.calculateSupplyRate(input), expectedNetSupplyRate, "Net supply rate (0% reserve factor, 50% util)");

    //     // Scenario 3: High Utilization, Non-Zero Reserve Factor (10%)
    //     input.riskParams = riskParams; // Reset to original riskParams with 10% reserveFactor
    //     input.totalBorrowedPrincipal = 90e18;
    //     input.totalPolynanceSupply = 100e18;
    //     uint256 utilization3 = Core.calculateUtilization(input.totalBorrowedPrincipal, input.totalPolynanceSupply);
    //     uint256 pureSpreadRate3 = Core.calculateSpreadRate(Core.CalcPureSpreadRateInput({
    //         totalBorrowedPrincipal: input.totalBorrowedPrincipal,
    //         totalPolynanceSupply: input.totalPolynanceSupply,
    //         riskParams: input.riskParams
    //     }));
    //     uint256 grossSupplyRate3 = pureSpreadRate3.rayMul(utilization3);
    //     expectedNetSupplyRate = OZMath.mulDiv(grossSupplyRate3, (PERCENTAGE_FACTOR - riskParams.reserveFactor), PERCENTAGE_FACTOR);
    //     assertEq(Core.calculateSupplyRate(input), expectedNetSupplyRate, "Net supply rate (10% reserve factor, 90% util)");

    //     // Scenario 4: Zero Utilization
    //     input.totalBorrowedPrincipal = 0;
    //     uint256 utilization4 = Core.calculateUtilization(input.totalBorrowedPrincipal, input.totalPolynanceSupply);
    //     uint256 pureSpreadRate4 = Core.calculateSpreadRate(Core.CalcPureSpreadRateInput({
    //         totalBorrowedPrincipal: input.totalBorrowedPrincipal,
    //         totalPolynanceSupply: input.totalPolynanceSupply,
    //         riskParams: input.riskParams
    //     }));
    //     uint256 grossSupplyRate4 = pureSpreadRate4.rayMul(utilization4);
    //     expectedNetSupplyRate = OZMath.mulDiv(grossSupplyRate4, (PERCENTAGE_FACTOR - riskParams.reserveFactor), PERCENTAGE_FACTOR);
    //     assertEq(Core.calculateSupplyRate(input), expectedNetSupplyRate, "Net supply rate (10% reserve factor, 0% util)");
    // }

    // Test: Update Indices
    function test_updateIndices() public {
        // Set initial state
        reserveData.totalBorrowed = 50e18;
        uint256 totalSupply = 100e18;
        
        // Move time forward by 1 year
        vm.warp(block.timestamp + 365 days);
        
        Core.UpdateIndicesInput memory input = Core.UpdateIndicesInput({
            reserve: reserveData,
            riskParams: riskParams,
            currentTotalBorrowedPrincipal: 50e18,
            currentTotalSupplyPrincipal: totalSupply
        });
        
        (uint256 newBorrowIndex, uint256 newLiquidityIndex, uint256 newAccumulatedSpread) = Core.updateIndices(input);
        
        // Verify indices increased
        assertGt(newBorrowIndex, RAY, "Borrow index should increase (basic check)");
        assertGt(newLiquidityIndex, RAY, "Liquidity index should increase (basic check)");
        assertGt(newAccumulatedSpread, 0, "Accumulated spread should increase (basic check)");
    }

    // Test: Update Indices with Precise Value Checks
    // This test assumes that the liquidityIndex is updated based on the NET supply rate (after reserveFactor).
    function test_updateIndices_precise() public {
        Storage.ReserveData memory currentReserve = reserveData;
        currentReserve.totalBorrowed = 50e18; // For accumulatedSpread calculation
        currentReserve.lastUpdateTimestamp = uint40(block.timestamp);
        currentReserve.variableBorrowIndex = RAY;
        currentReserve.liquidityIndex = RAY;
        currentReserve.accumulatedSpread = 0;

        uint256 currentTotalBorrowedPrincipal = 50e18;
        uint256 currentTotalSupplyPrincipal = 100e18;
        uint256 timeDelta = 365 days; // 1 year

        // Setup input for Core.updateIndices
        Core.UpdateIndicesInput memory updateInput = Core.UpdateIndicesInput({
            reserve: currentReserve,
            riskParams: riskParams, // Uses riskParams.reserveFactor = 1000 (10%)
            currentTotalBorrowedPrincipal: currentTotalBorrowedPrincipal,
            currentTotalSupplyPrincipal: currentTotalSupplyPrincipal
        });

        // Calculate expected values BEFORE advancing time
        // 1. Expected Pure Spread Rate
        uint256 expectedPureSpreadRate = Core.calculateSpreadRate(Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: currentTotalBorrowedPrincipal,
            totalPolynanceSupply: currentTotalSupplyPrincipal,
            riskParams: riskParams
        }));

        // 2. Expected LP Supply Rate (NET, after reserve factor)
        // This calculation assumes Core.calculateSupplyRate returns NET. If it returns GROSS, this test logic needs adjustment
        // or Core.calculateSupplyRate needs to be fixed.
        // For this test, we calculate the expected NET rate manually based on the intended logic.
        uint256 utilization = Core.calculateUtilization(currentTotalBorrowedPrincipal, currentTotalSupplyPrincipal);
        uint256 grossLpSupplyRate = expectedPureSpreadRate.rayMul(utilization);
        uint256 expectedNetLpSupplyRate = OZMath.mulDiv(grossLpSupplyRate, (PERCENTAGE_FACTOR - riskParams.reserveFactor), PERCENTAGE_FACTOR);

        uint256 timestampBeforeWarp = block.timestamp;
        // Advance time
        vm.warp(timestampBeforeWarp + timeDelta);
        uint256 timestampAfterWarp = block.timestamp;

        // Call Core.updateIndices
        (uint256 newBorrowIndex, uint256 newLiquidityIndex, uint256 newAccumulatedSpread) = Core.updateIndices(updateInput);

        // Calculate expected compounded factors using MathUtils.calculateCompoundedInterest
        uint256 expectedNewBorrowIndex = MathUtils.calculateCompoundedInterest(
            expectedPureSpreadRate,
            uint40(timestampBeforeWarp), // lastUpdateTimestamp for this calculation interval
            timestampAfterWarp
        ).rayMul(currentReserve.variableBorrowIndex);

        uint256 expectedNewLiquidityIndex = MathUtils.calculateCompoundedInterest(
            expectedNetLpSupplyRate, // Using NET rate for liquidity index
            uint40(timestampBeforeWarp), // lastUpdateTimestamp for this calculation interval
            timestampAfterWarp
        ).rayMul(currentReserve.liquidityIndex);
        
        // 3. Expected Accumulated Spread
        uint256 intermediateSpreadProduct = currentReserve.totalBorrowed.rayMul(expectedPureSpreadRate);
        uint256 expectedSpreadEarnedThisPeriod = OZMath.mulDiv(intermediateSpreadProduct, timeDelta, SECONDS_PER_YEAR);
        uint256 expectedNewAccumulatedSpread = currentReserve.accumulatedSpread + expectedSpreadEarnedThisPeriod;

        // Assertions
        assertEq(newBorrowIndex, expectedNewBorrowIndex, "Precise new borrow index check");
        assertEq(newLiquidityIndex, expectedNewLiquidityIndex, "Precise new liquidity index check (using NET rate)");
        assertEq(newAccumulatedSpread, expectedNewAccumulatedSpread, "Precise new accumulated spread check");
    }
    
    // Test: Calculate User Total Debt
    function test_calculateUserTotalDebt() public {
        Core.CalcUserTotalDebtInput memory input = Core.CalcUserTotalDebtInput({
            principalDebt: 100e18, // 100 tokens borrowed with Aave interest
            scaledPolynanceSpreadDebtPrincipal: 95e18, // Scaled principal
            initialBorrowAmount: 90e18, // Initial borrow amount
            currentPolynanceSpreadBorrowIndex: 1.1e27 // 10% increase
        });
        
        (uint256 totalDebt, uint256 principalDebt, uint256 pureSpreadInterest) = Core.calculateUserTotalDebt(input);
        
        // Total value from spread = 95e18 * 1.1 = 104.5e18
        // Pure spread interest = 104.5e18 - 90e18 = 14.5e18
        // Total debt = 100e18 + 14.5e18 = 114.5e18
        assertEq(totalDebt, 114.5e18, "Total debt calculation");
        assertEq(principalDebt, 100e18, "Principal debt should remain unchanged");
        assertEq(pureSpreadInterest, 14.5e18, "Pure spread interest calculation");
    }
    
    // Test: Calculate Max Borrow
    function test_calculateBorrowAble() public {
        Core.CalcMaxBorrowInput memory input = Core.CalcMaxBorrowInput({
            collateralAmount: 1e18, // 1 ETH
            collateralPrice: 2000e27, // $2000 per ETH in RAY
            ltv: LTV, // 75%
            supplyAssetDecimals:6, // USDC has 6 decimals in reality, but using 18 for simplicity
            collateralAssetDecimals: 18
        });
        
        uint256 maxBorrow = Core.calculateBorrowAble(input);
        // Expected: 1 ETH * $2000 * 75% = $1500
        assertEq(maxBorrow, 1500e6, "Max borrow calculation");
    }
    
    // Test: Calculate Health Factor
    function test_calculateHealthFactor() public {
        Core.CalcHealthFactorInput memory input = Core.CalcHealthFactorInput({
            collateralAmount: 1e18, // 1 ETH
            collateralPrice: 2000e27, // $2000 per ETH
            userTotalDebt: 1000e18, // $1000 debt
            liquidationThreshold: LIQUIDATION_THRESHOLD, // 85%
            supplyAssetDecimals: 18,
            collateralAssetDecimals: 18
        });
        
        uint256 healthFactor = Core.calculateHealthFactor(input);
        // Expected: (1 ETH * $2000 * 85%) / $1000 = $1700 / $1000 = 1.7
        assertEq(healthFactor, 1.7e27, "Health factor calculation");
        
        // Test with zero debt
        input.userTotalDebt = 0;
        healthFactor = Core.calculateHealthFactor(input);
        assertEq(healthFactor, type(uint256).max, "Health factor should be max when debt is 0");
    }
    
    // Test: Is Position Healthy
    function test_isPositionHealthy() public {
        assertTrue(Core.isPositionHealthy(1.5e27), "Position with HF > 1 should be healthy");
        assertTrue(Core.isPositionHealthy(RAY), "Position with HF = 1 should be healthy");
        assertFalse(Core.isPositionHealthy(0.9e27), "Position with HF < 1 should be unhealthy");
    }
    
    // Test: Validate Borrow
    function test_validateBorrow() public {
        uint256 totalSupply = 1000e18;
        uint256 existingBorrows = 500e18;
        uint256 borrowAmount = 200e18;
        uint256 maxBorrowForUser = 300e18;
        
        // Valid borrow
        assertTrue(
            Core.validateBorrow(
                existingBorrows + borrowAmount,
                totalSupply,
                borrowAmount,
                maxBorrowForUser
            ),
            "Valid borrow should pass"
        );
        
        // Exceeds user limit
        assertFalse(
            Core.validateBorrow(
                existingBorrows + 400e18,
                totalSupply,
                400e18,
                maxBorrowForUser
            ),
            "Borrow exceeding user limit should fail"
        );
        
        // Exceeds total supply
        assertFalse(
            Core.validateBorrow(
                existingBorrows + 600e18,
                totalSupply,
                600e18,
                700e18
            ),
            "Borrow exceeding total supply should fail"
        );
    }
    
    // Test: Calculate Supply Shares
    function test_calculateSupplyShares() public {
        Core.CalcSupplyInput memory input = Core.CalcSupplyInput({
            supplyAmount: 100e18,
            currentLiquidityIndex: 1.1e27 // 10% increase
        });
        
        uint256 lpTokens = Core.calculateSupplyShares(input);
        // Expected: 100e18 / 1.1 ≈ 90.9e18
        assertApproxEqAbs(lpTokens, 90.909090909090909090e18, 1e9, "LP tokens calculation");
    }
    
    // Test: Validate Supply
    function test_validateSupply() public {
        assertTrue(Core.validateSupply(100e18), "Positive supply should be valid");
        assertFalse(Core.validateSupply(0), "Zero supply should be invalid");
    }
    
    // Test: Validate Withdraw
    function test_validateWithdraw() public {
        assertTrue(
            Core.validateWithdraw(50e18, 100e18, 1000e18),
            "Valid withdrawal should pass"
        );
        
        assertFalse(
            Core.validateWithdraw(0, 100e18, 1000e18),
            "Zero withdrawal should fail"
        );
        
        assertFalse(
            Core.validateWithdraw(150e18, 100e18, 1000e18),
            "Withdrawal exceeding balance should fail"
        );
        
        assertFalse(
            Core.validateWithdraw(50e18, 100e18, 0),
            "Withdrawal with no liquidity should fail"
        );
    }
    
    // Test: Calculate Scaled Supply Balance
    function test_calculateScaledSupplyBalance() public {
        uint256 supplyAmount = 100e18;
        uint256 liquidityIndex = 1.2e27; // 20% increase
        
        uint256 scaledBalance = Core.calculateScaledSupplyBalance(supplyAmount, liquidityIndex);
        // Expected: 100e18 / 1.2 ≈ 83.33e18
        assertApproxEqAbs(scaledBalance, 83.333333333333333333e18, 1e9, "Scaled balance calculation");
    }
    
    // Test: Calculate Supply Position Value
    function test_calculateSupplyPositionValue() public {
        Storage.SupplyPosition memory position = Storage.SupplyPosition({
            supplyAmount: 100e18, // Initial supply
            scaledSupplyBalance: 90e18, // Scaled balance
            scaledSupplyBalancePrincipal: 95e18 // Scaled balance at Aave (removed suppliedAt)
        });
        
        Core.CalcSupplyPositionValueInput memory input = Core.CalcSupplyPositionValueInput({
            position: position,
            currentLiquidityIndex: 1.15e27, // 15% increase
            principalWithdrawAmount: 105e18 // Principal + Aave interest
        });
        
        (uint256 totalWithdrawable, uint256 aaveInterest, uint256 polynanceInterest) = 
            Core.calculateSupplyPositionValue(input);
        
        // Polynance value = 90e18 * 1.15 = 103.5e18
        // Aave interest = 105e18 - 100e18 = 5e18
        // Polynance interest = 103.5e18 - 100e18 = 3.5e18
        // Total = 100e18 + 5e18 + 3.5e18 = 108.5e18
        assertEq(totalWithdrawable, 108.5e18, "Total withdrawable calculation");
        assertEq(aaveInterest, 5e18, "Aave interest calculation");
        assertEq(polynanceInterest, 3.5e18, "Polynance interest calculation");
    }
    
    // Test: Edge Cases and Realistic Scenarios
    function test_realisticLendingScenario() public {
        // Scenario: Market with moderate activity
        uint256 totalSupply = 10_000_000e18; // 10M tokens supplied
        uint256 totalBorrowed = 7_500_000e18; // 7.5M tokens borrowed (75% utilization)
        
        // Calculate rates
        Core.CalcPureSpreadRateInput memory spreadInput = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: totalBorrowed,
            totalPolynanceSupply: totalSupply,
            riskParams: riskParams
        });
        
        uint256 spreadRate = Core.calculateSpreadRate(spreadInput);
        uint256 utilization = Core.calculateUtilization(totalBorrowed, totalSupply);
        
        assertEq(utilization, 0.75e27, "Utilization should be 75%");
        
        // Simulate 30 days of interest accrual
        reserveData.totalBorrowed = totalBorrowed;
        vm.warp(block.timestamp + 30 days);
        
        Core.UpdateIndicesInput memory updateInput = Core.UpdateIndicesInput({
            reserve: reserveData,
            riskParams: riskParams,
            currentTotalBorrowedPrincipal: totalBorrowed,
            currentTotalSupplyPrincipal: totalSupply
        });
        
        (uint256 newBorrowIndex, uint256 newLiquidityIndex, uint256 newAccumulatedSpread) = 
            Core.updateIndices(updateInput);
        
        // Verify reasonable interest accrual over 30 days
        uint256 borrowIndexIncrease = newBorrowIndex - RAY;
        uint256 expectedMonthlyRate = spreadRate * 30 days / SECONDS_PER_YEAR;
        
        // Allow for compound interest difference
        assertApproxEqRel(
            borrowIndexIncrease, 
            expectedMonthlyRate, 
            0.01e18, // 1% tolerance
            "Borrow index increase should match expected rate"
        );
    }
    
    // Test: High Utilization Scenario
    function test_highUtilizationScenario() public {
        uint256 totalSupply = 1_000_000e18;
        uint256 totalBorrowed = 950_000e18; // 95% utilization
        
        Core.CalcPureSpreadRateInput memory input = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: totalBorrowed,
            totalPolynanceSupply: totalSupply,
            riskParams: riskParams
        });
        
        uint256 spreadRate = Core.calculateSpreadRate(input);
        
        // At 95% utilization, we're 15% above optimal (80%)
        // Expected rate = base + slope1 * 0.8 + slope2 * 0.15
        uint256 expectedRate = BASE_SPREAD_RATE + 
            SLOPE1.rayMul(OPTIMAL_UTILIZATION) + 
            SLOPE2.rayMul(0.15e27);
        
        assertEq(spreadRate, expectedRate, "High utilization spread rate");
        
        // Verify this creates strong incentive for repayment
        assertGt(spreadRate, 0.15e27, "Spread rate should be > 15% at high utilization");
    }
    
    // Test: Liquidation Scenario
    function test_liquidationScenario() public {
        // User has 1 ETH collateral at $2000, borrowed $1600 (80% LTV initially)
        uint256 collateralAmount = 1e18;
        uint256 initialPrice = 2000e27;
        uint256 debt = 1600e18;
        
        // Price drops to $1850
        uint256 newPrice = 1850e27;
        
        Core.CalcHealthFactorInput memory input = Core.CalcHealthFactorInput({
            collateralAmount: collateralAmount,
            collateralPrice: newPrice,
            userTotalDebt: debt,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            supplyAssetDecimals: 18,
            collateralAssetDecimals: 18
        });
        
        uint256 healthFactor = Core.calculateHealthFactor(input);
        // HF = (1 ETH * $1850 * 85%) / $1600 = $1572.5 / $1600 ≈ 0.983
        
        assertLt(healthFactor, RAY, "Health factor should be below 1");
        assertFalse(Core.isPositionHealthy(healthFactor), "Position should be unhealthy");
    }
    
    // Test: Zero edge cases
    function test_zeroEdgeCases() public {
        // Test all functions with zero inputs
        assertEq(Core.calculateUtilization(0, 0), 0, "Zero utilization");
        
        Core.CalcPureSpreadRateInput memory spreadInput = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: 0,
            totalPolynanceSupply: 0,
            riskParams: riskParams
        });
        assertEq(Core.calculateSpreadRate(spreadInput), BASE_SPREAD_RATE, "Base spread rate with zero utilization");
        
        Core.CalcUserTotalDebtInput memory debtInput = Core.CalcUserTotalDebtInput({
            principalDebt: 0,
            scaledPolynanceSpreadDebtPrincipal: 0,
            initialBorrowAmount: 0,
            currentPolynanceSpreadBorrowIndex: RAY
        });
        (uint256 totalDebt,,) = Core.calculateUserTotalDebt(debtInput);
        assertEq(totalDebt, 0, "Zero debt calculation");
    }
    
    // ============================================
    // Additional Mathematical Accuracy Tests
    // ============================================
    
    // Test: Precision in Interest Calculations
    function test_interestAccumulationPrecision() public {
        // Test small incremental time updates to ensure precision
        reserveData.totalBorrowed = 1_000_000e18;
        uint256 totalSupply = 1_000_000e18; // 100% utilization
        
        uint256 cumulativeBorrowIndex = RAY;
        uint256 cumulativeLiquidityIndex = RAY;
        
        // Simulate 365 daily updates
        for (uint256 i = 0; i < 365; i++) {
            vm.warp(block.timestamp + 1 days);
            
            Core.UpdateIndicesInput memory input = Core.UpdateIndicesInput({
                reserve: Storage.ReserveData({
                    variableBorrowIndex: cumulativeBorrowIndex,
                    liquidityIndex: cumulativeLiquidityIndex,
                    lastUpdateTimestamp: block.timestamp - 1 days,
                    totalBorrowed: reserveData.totalBorrowed,
                    totalSupplied: totalSupply,
                    accumulatedSpread: 0,
                    totalCollateral: 0,
                    cachedUtilization: 0,
                    accumulatedRedeemed: 0,
                    accumulatedReserves: 0
                }),
                riskParams: riskParams,
                currentTotalBorrowedPrincipal: reserveData.totalBorrowed,
                currentTotalSupplyPrincipal: totalSupply
            });
            
            (cumulativeBorrowIndex, cumulativeLiquidityIndex,) = Core.updateIndices(input);
        }
        
        // After 365 days at 100% utilization with base rate + slope1 * 0.8 + slope2 * 0.2
        uint256 expectedAnnualRate = BASE_SPREAD_RATE + SLOPE1.rayMul(OPTIMAL_UTILIZATION) + SLOPE2.rayMul(0.2e27);
        
        // The compound index growth will be higher than simple interest
        // For an annual rate of ~25.2%, compound growth over 365 daily updates will be:
        // (1 + r/365)^365 - 1 ≈ 0.2866 (28.66%) vs simple 0.252 (25.2%)
        uint256 borrowIndexGrowth = cumulativeBorrowIndex - RAY;
        
        // Allow for compound interest being higher than simple interest
        assertGt(borrowIndexGrowth, expectedAnnualRate, "Compound interest should be higher than simple interest");
        // But it shouldn't be more than 15% higher for reasonable rates
        assertLt(borrowIndexGrowth, expectedAnnualRate.rayMul(1.15e27), "Compound interest shouldn't be too high");
    }
    
    // Test: Extreme Utilization Rates
    function test_extremeUtilizationRates() public {
        Core.CalcPureSpreadRateInput memory input;
        
        // Test 0.01% utilization
        input = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: 1e16, // 0.01 tokens
            totalPolynanceSupply: 100e18, // 100 tokens
            riskParams: riskParams
        });
        uint256 spreadRate = Core.calculateSpreadRate(input);
        uint256 expectedRate = BASE_SPREAD_RATE + SLOPE1.rayMul(0.0001e27);
        assertEq(spreadRate, expectedRate, "Spread rate at 0.01% utilization");
        
        // Test 99.99% utilization
        input.totalBorrowedPrincipal = 99.99e18;
        spreadRate = Core.calculateSpreadRate(input);
        expectedRate = BASE_SPREAD_RATE + SLOPE1.rayMul(OPTIMAL_UTILIZATION) + SLOPE2.rayMul(0.1999e27);
        assertApproxEqAbs(spreadRate, expectedRate, 1e18, "Spread rate at 99.99% utilization");
        
        // Test exactly at optimal utilization
        input.totalBorrowedPrincipal = 80e18;
        spreadRate = Core.calculateSpreadRate(input);
        expectedRate = BASE_SPREAD_RATE + SLOPE1.rayMul(OPTIMAL_UTILIZATION);
        assertEq(spreadRate, expectedRate, "Spread rate at exactly optimal utilization");
    }
    
    // Test: Debt Calculation with Maximum Values
    function test_debtCalculationMaxValues() public {
        // Test with large but safe values to avoid overflow
        uint256 largeValue = 1e36; // Large but safe value
        
        Core.CalcUserTotalDebtInput memory input = Core.CalcUserTotalDebtInput({
            principalDebt: largeValue,
            scaledPolynanceSpreadDebtPrincipal: largeValue.rayDiv(1.1e27),
            initialBorrowAmount: largeValue - 1000e18,
            currentPolynanceSpreadBorrowIndex: 1.1e27
        });
        
        (uint256 totalDebt, uint256 principalDebt, uint256 pureSpreadInterest) = Core.calculateUserTotalDebt(input);
        
        assertTrue(totalDebt > principalDebt, "Total debt should include spread interest");
        assertEq(principalDebt, largeValue, "Principal debt should remain unchanged");
        assertTrue(pureSpreadInterest > 0, "Pure spread interest should be positive");
    }
    
    // Test: Health Factor Edge Cases
    function test_healthFactorEdgeCases() public {
        Core.CalcHealthFactorInput memory input;
        
        // Test with very small debt (dust)
        input = Core.CalcHealthFactorInput({
            collateralAmount: 1e18,
            collateralPrice: 2000e27,
            userTotalDebt: 1, // 1 wei
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            supplyAssetDecimals: 18,
            collateralAssetDecimals: 18
        });
        
        uint256 healthFactor = Core.calculateHealthFactor(input);
        assertTrue(healthFactor > 1000e27, "Health factor with dust debt should be very high");
        
        // Test with collateral value exactly equal to debt at liquidation threshold
        input.userTotalDebt = 1700e18; // Exactly at liquidation threshold
        healthFactor = Core.calculateHealthFactor(input);
        assertEq(healthFactor, RAY, "Health factor should be exactly 1 at liquidation threshold");
        
        // Test with different decimal configurations
        input = Core.CalcHealthFactorInput({
            collateralAmount: 1e8, // 1 BTC with 8 decimals
            collateralPrice: 50000e27, // $50,000 per BTC
            userTotalDebt: 30000e6, // $30,000 USDC with 6 decimals
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            supplyAssetDecimals: 6, // USDC
            collateralAssetDecimals: 8 // BTC
        });
        
        healthFactor = Core.calculateHealthFactor(input);
        // Expected: (1 BTC * $50,000 * 85%) / $30,000 = $42,500 / $30,000 ≈ 1.417
        assertApproxEqAbs(healthFactor, 1.417e27, 0.001e27, "Health factor with different decimals");
    }
    
    // Test: Supply Rate Mathematical Properties
    function test_supplyRateMathematicalProperties() public {
        // Property: Supply rate should always be less than or equal to spread rate
        for (uint256 util = 0; util <= 100; util += 10) {
            Core.CalcPureSpreadRateInput memory spreadInput = Core.CalcPureSpreadRateInput({
                totalBorrowedPrincipal: util * 1e18,
                totalPolynanceSupply: 100e18,
                riskParams: riskParams
            });
            
            uint256 spreadRate = Core.calculateSpreadRate(spreadInput);
            
            Core.CalcSupplyRateInput memory supplyInput = Core.CalcSupplyRateInput({
                totalBorrowedPrincipal: util * 1e18,
                totalPolynanceSupply: 100e18,
                riskParams: riskParams
            });
            
            uint256 supplyRate = Core.calculateSupplyRate(supplyInput);
            
            assertLe(supplyRate, spreadRate, "Supply rate should be <= spread rate");
            
            // Calculate expected GROSS supply rate
            // Core.calculateSupplyRate now returns gross rate.
            uint256 expectedGrossSupplyRate = spreadRate.rayMul(util * RAY / 100); // util is in %, convert to RAY factor
            assertEq(supplyRate, expectedGrossSupplyRate, "Gross supply rate formula verification");
        }
    }
    
    // Test: Scaled Balance Precision
    function test_scaledBalancePrecision() public {
        // Test that scaling and unscaling preserves value within acceptable precision
        uint256[] memory testAmounts = new uint256[](5);
        testAmounts[0] = 1; // 1 wei
        testAmounts[1] = 1e6; // 1 micro token
        testAmounts[2] = 1e18; // 1 token
        testAmounts[3] = 1_000_000e18; // 1M tokens
        testAmounts[4] = type(uint256).max / 1e30; // Near max value
        
        uint256[] memory testIndices = new uint256[](4);
        testIndices[0] = RAY; // No change
        testIndices[1] = 1.01e27; // 1% increase
        testIndices[2] = 2e27; // 100% increase
        testIndices[3] = 0.5e27; // 50% decrease (should not happen in practice)
        
        for (uint256 i = 0; i < testAmounts.length; i++) {
            for (uint256 j = 0; j < testIndices.length; j++) {
                uint256 scaledBalance = Core.calculateScaledSupplyBalance(testAmounts[i], testIndices[j]);
                uint256 unscaledBalance = scaledBalance.rayMul(testIndices[j]);
                
                // For very small amounts, allow absolute error of 1 wei
                if (testAmounts[i] < 1e6) {
                    assertApproxEqAbs(unscaledBalance, testAmounts[i], 1, "Scaling precision for small amounts");
                } else {
                    // For larger amounts, use relative error tolerance of 0.0001%
                    assertApproxEqRel(unscaledBalance, testAmounts[i], 0.000001e18, "Scaling precision for large amounts");
                }
            }
        }
    }
    
    // Test: Borrow Validation Boundary Conditions
    function test_borrowValidationBoundaries() public {
        uint256 totalSupply = 1000e18;
        uint256 existingBorrows = 500e18;
        
        // Test borrowing exactly the remaining supply
        assertTrue(
            Core.validateBorrow(
                totalSupply,
                totalSupply,
                500e18,
                500e18
            ),
            "Borrowing exactly remaining supply should be valid"
        );
        
        // Test borrowing 1 wei more than available
        assertFalse(
            Core.validateBorrow(
                existingBorrows + 500e18 + 1,
                totalSupply,
                500e18 + 1,
                600e18
            ),
            "Borrowing 1 wei more than available should fail"
        );
        
        // Test with zero total supply
        assertFalse(
            Core.validateBorrow(
                1,
                0,
                1,
                1
            ),
            "Cannot borrow when total supply is zero"
        );
    }
    
    // Test: Compound Interest Accuracy Over Time
    function test_compoundInterestAccuracy() public {
        // Test that compound interest calculation is accurate over different time periods
        uint256 annualRate = 0.1e27; // 10% annual rate
        uint256 principal = 1000e18;
        
        reserveData.totalBorrowed = principal;
        reserveData.variableBorrowIndex = RAY;
        
        // Test different time periods
        uint256[] memory timePeriods = new uint256[](5);
        timePeriods[0] = 1 hours;
        timePeriods[1] = 1 days;
        timePeriods[2] = 7 days;
        timePeriods[3] = 30 days;
        timePeriods[4] = 365 days;
        
        for (uint256 i = 0; i < timePeriods.length; i++) {
            vm.warp(block.timestamp + timePeriods[i]);
            
            Core.UpdateIndicesInput memory input = Core.UpdateIndicesInput({
                reserve: reserveData,
                riskParams: Storage.RiskParams({
                    interestRateMode: InterestRateMode.VARIABLE,
                    baseSpreadRate: annualRate,
                    slope1: 0,
                    slope2: 0,
                    optimalUtilization: RAY,
                    reserveFactor: 0,
                    ltv: LTV,
                    liquidationThreshold: LIQUIDATION_THRESHOLD,
                    maturityDate: block.timestamp + 365 days,
                    priceOracle: address(0x1),
                    aaveModule: address(0x2),
                    supplyAsset: address(0x3),
                    collateralAsset: address(0x4),
                    supplyAssetDecimals: 18,
                    collateralAssetDecimals: 18,
                    curator: address(this),
                    isActive: true,
                    lpShareOfRedeemed:10
                }),
                currentTotalBorrowedPrincipal: principal,
                currentTotalSupplyPrincipal: principal
            });
            
            (uint256 newBorrowIndex,,) = Core.updateIndices(input);
            
            // Calculate expected simple interest
            uint256 timeRatio = timePeriods[i] * RAY / SECONDS_PER_YEAR;
            uint256 expectedSimpleGrowth = annualRate.rayMul(timeRatio);
            uint256 actualGrowth = newBorrowIndex - RAY;
            
            // For very short time periods (up to 1 day), compound and simple interest are very close
            if (timePeriods[i] <= 1 days) {
                // Allow 5% relative error for very short periods due to compound interest
                assertApproxEqRel(actualGrowth, expectedSimpleGrowth, 0.05e18, "Short-term interest accuracy");
            } else {
                // For longer periods, compound interest should be noticeably higher
                assertGt(newBorrowIndex, RAY + expectedSimpleGrowth, "Compound interest should exceed simple interest");
                
                // But validate it's within reasonable bounds (not more than double for 10% annual rate)
                assertLt(actualGrowth, expectedSimpleGrowth * 2, "Compound interest should be reasonable");
            }
            
            // Reset for next iteration
            reserveData.lastUpdateTimestamp = block.timestamp - timePeriods[i];
        }
    }
    
    // Test: Accumulated Spread Calculation
    function test_accumulatedSpreadCalculation() public {
        uint256 totalBorrowed = 1_000_000e18;
        uint256 totalSupply = 2_000_000e18;
        uint256 spreadRate = 0.05e27; // 5% annual
        
        reserveData.totalBorrowed = totalBorrowed;
        
        // Calculate expected spread for 1 year
        vm.warp(block.timestamp + 365 days);
        
        Core.UpdateIndicesInput memory input = Core.UpdateIndicesInput({
            reserve: reserveData,
            riskParams: Storage.RiskParams({
                interestRateMode: InterestRateMode.VARIABLE,
                baseSpreadRate: spreadRate,
                slope1: 0,
                slope2: 0,
                optimalUtilization: RAY,
                reserveFactor: 0,
                ltv: LTV,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maturityDate: block.timestamp + 365 days,
                priceOracle: address(0x1),
                aaveModule: address(0x2),
                supplyAsset: address(0x3),
                collateralAsset: address(0x4),
                supplyAssetDecimals: 18,
                collateralAssetDecimals: 18,
                curator: address(this),
                isActive: true,
                lpShareOfRedeemed: 10
            }),
            currentTotalBorrowedPrincipal: totalBorrowed,
            currentTotalSupplyPrincipal: totalSupply
        });
        
        (,, uint256 accumulatedSpread) = Core.updateIndices(input);
        
        // Expected spread = totalBorrowed * spreadRate * 1 year
        uint256 expectedSpread = totalBorrowed.rayMul(spreadRate);
        
        assertApproxEqRel(accumulatedSpread, expectedSpread, 0.001e18, "Accumulated spread calculation");
    }
    
    // Fuzz Tests
    
    // Fuzz: Utilization Calculation Properties
    function testFuzz_utilizationProperties(uint256 borrowed, uint256 supply) public {
        // Bound inputs to reasonable ranges
        borrowed = bound(borrowed, 0, type(uint128).max);
        supply = bound(supply, 1, type(uint128).max); // At least 1 to avoid division by zero
        
        if (borrowed > supply) {
            // Swap if borrowed > supply to test valid scenarios
            (borrowed, supply) = (supply, borrowed);
        }
        
        uint256 utilization = Core.calculateUtilization(borrowed, supply);
        
        // Properties:
        // 1. Utilization should be between 0 and 100%
        assertLe(utilization, RAY, "Utilization should not exceed 100%");
        
        // 2. If borrowed = 0, utilization = 0
        if (borrowed == 0) {
            assertEq(utilization, 0, "Zero borrowed should yield zero utilization");
        }
        
        // 3. If borrowed = supply, utilization = 100%
        if (borrowed == supply) {
            assertEq(utilization, RAY, "Full utilization when borrowed equals supply");
        }
        
        // 4. Utilization calculation should be consistent
        uint256 recalculated = Core.calculateUtilization(borrowed, supply);
        assertEq(utilization, recalculated, "Utilization calculation should be deterministic");
    }
    
    // Test specific failing case from fuzz test for health factor
    function test_healthFactor_specificCaseFromFuzz() public pure {
        Core.CalcHealthFactorInput memory input = Core.CalcHealthFactorInput({
            collateralAmount: 0, // From counterexample
            // collateralPriceFuzz from counterexample: 340282366920938463463374607431768211453
            collateralPrice: uint256(340282366920938463463374607431768211453) * RAY / 1e18, 
            // userDebtFuzz from counterexample: 176760516036943477933930482067886
            userTotalDebt: 176760516036943477933930482067886, 
            liquidationThreshold: LIQUIDATION_THRESHOLD, // Default 85%
            supplyAssetDecimals: 18,
            collateralAssetDecimals: 18
        });

        uint256 healthFactor = Core.calculateHealthFactor(input);
        assertEq(healthFactor, 0, "Health factor for 0 collateral, non-zero debt should be 0");
    }

    // Fuzz: Health Factor Never Overflows
    function testFuzz_healthFactorOverflow(
        uint128 collateralAmount,
        uint128 collateralPriceFuzz, // Renamed to avoid clash
        uint128 userDebtFuzz         // Renamed to avoid clash
    ) public pure { // Changed to pure
        uint128 effectiveUserDebt = userDebtFuzz;
        if (effectiveUserDebt == 0) effectiveUserDebt = 1; // Ensure non-zero debt for this test's main path
        
        uint128 effectiveCollateralPrice = collateralPriceFuzz;
        if (effectiveCollateralPrice == 0) effectiveCollateralPrice = 1; // Ensure collateral price is non-zero for scaling
        
        Core.CalcHealthFactorInput memory input = Core.CalcHealthFactorInput({
            collateralAmount: collateralAmount,
            collateralPrice: uint256(effectiveCollateralPrice) * RAY / 1e18, // Convert to RAY
            userTotalDebt: effectiveUserDebt,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            supplyAssetDecimals: 18,
            collateralAssetDecimals: 18
        });
        
        uint256 healthFactor = Core.calculateHealthFactor(input);
        
        // Updated assertion logic for health factor validity
        if (input.collateralAmount == 0) { // If collateral is 0 (and debt > 0 due to effectiveUserDebt logic)
            assertEq(healthFactor, 0, "HF should be 0 for zero collateral and non-zero debt");
        } else { // Collateral > 0 and debt > 0
            // Health factor can be 0 if collateral value is very low compared to debt.
            // The main check is that it's not type(uint256).max, as debt is non-zero.
            assertTrue(healthFactor != type(uint256).max, 
                "HF should not be type(uint256).max if debt is non-zero and collateral > 0");
        }
    }
    
    // Fuzz: Interest Rate Model Monotonicity
    function testFuzz_interestRateMonotonicity(uint8 utilization1, uint8 utilization2) public {
        if (utilization1 > utilization2) {
            (utilization1, utilization2) = (utilization2, utilization1);
        }
        
        // Convert utilization percentages to actual amounts
        uint256 totalSupply = 100e18;
        uint256 borrowed1 = uint256(utilization1) * totalSupply / 100;
        uint256 borrowed2 = uint256(utilization2) * totalSupply / 100;
        
        Core.CalcPureSpreadRateInput memory input1 = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: borrowed1,
            totalPolynanceSupply: totalSupply,
            riskParams: riskParams
        });
        
        Core.CalcPureSpreadRateInput memory input2 = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: borrowed2,
            totalPolynanceSupply: totalSupply,
            riskParams: riskParams
        });
        
        uint256 rate1 = Core.calculateSpreadRate(input1);
        uint256 rate2 = Core.calculateSpreadRate(input2);
        
        // Property: Higher utilization should never result in lower spread rate
        assertGe(rate2, rate1, "Interest rate should be monotonically increasing with utilization");
    }
} 