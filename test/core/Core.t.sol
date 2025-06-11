// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/Core.sol";
import "../../src/libraries/Storage.sol";

contract CoreTest is Test {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using Math for uint256;

    
    // Constants
    uint256 constant RAY = 1e27;
    uint256 constant WAD = 1e18;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    uint256 constant MAX_BPS = 10_000;
    
    // Realistic market parameters
    uint256 constant OPTIMAL_UTILIZATION = 0.8e27; // 80%
    uint256 constant BASE_SPREAD_RATE = 0.02e27; // 2% base spread
    uint256 constant SLOPE1 = 0.04e27; // 4% slope below optimal
    uint256 constant SLOPE2 = 0.75e27; // 75% slope above optimal
    uint256 constant RESERVE_FACTOR = 1000; // 10%
    uint256 constant LTV = 6000; // 60%
    uint256 constant LIQUIDATION_THRESHOLD = 7500; // 75%
    uint256 constant LP_SHARE_OF_REDEEMED = 5000; // 50%
    
    // Test assets decimals
    uint256 constant USDC_DECIMALS = 6;
    uint256 constant COLLATERAL_DECIMALS = 18;
    
    function setUp() public {
        // Setup test environment
    }
    
    // ============ Interest Rate Model Tests ============
    
    function test_CalculateUtilization() public {
        // Test zero supply
        uint256 utilization = Core.calculateUtilization(0, 0);
        assertEq(utilization, 0, "Zero supply should return 0 utilization");
        
        // Test normal utilization (50%)
        uint256 borrowed = 50_000e6; // 50k USDC
        uint256 supplied = 100_000e6; // 100k USDC
        utilization = Core.calculateUtilization(borrowed, supplied);
        assertEq(utilization, 0.5e27, "Should be 50% utilization");
        
        // Test high utilization (95%)
        borrowed = 95_000e6;
        supplied = 100_000e6;
        utilization = Core.calculateUtilization(borrowed, supplied);
        assertEq(utilization, 0.95e27, "Should be 95% utilization");
    }
    
    function test_CalculateSpreadRate_BelowOptimal() public {
        // Test spread rate when utilization is below optimal (50% < 80%)
        Core.CalcPureSpreadRateInput memory input = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: 50_000e6,
            totalPolynanceSupply: 100_000e6,
            riskParams: _getRiskParams()
        });
        
        uint256 spreadRate = Core.calculateSpreadRate(input);
        // Expected: baseRate + slope1 * utilization = 0.02 + 0.04 * 0.5 = 0.04 (4%)
        assertEq(spreadRate, 0.04e27, "Spread rate should be 4%");
    }
    
    function test_CalculateSpreadRate_AboveOptimal() public {
        // Test spread rate when utilization is above optimal (90% > 80%)
        Core.CalcPureSpreadRateInput memory input = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: 90_000e6,
            totalPolynanceSupply: 100_000e6,
            riskParams: _getRiskParams()
        });
        
        uint256 spreadRate = Core.calculateSpreadRate(input);
        // Expected: baseRate + slope1 * optimal + slope2 * (0.9 - 0.8)
        // = 0.02 + 0.04 * 0.8 + 0.75 * 0.1 = 0.02 + 0.032 + 0.075 = 0.127 (12.7%)
        uint256 expected = BASE_SPREAD_RATE + SLOPE1.rayMul(OPTIMAL_UTILIZATION) + SLOPE2.rayMul(0.1e27);
        assertApproxEqRel(spreadRate, expected, 0.001e18, "Spread rate should be ~12.7%");
    }
    
    function test_CalculateSupplyRate() public {
        // Test supply rate calculation (LP earnings)
        Core.CalcSupplyRateInput memory input = Core.CalcSupplyRateInput({
            totalBorrowedPrincipal: 80_000e6, // 80% utilization
            totalPolynanceSupply: 100_000e6,
            riskParams: _getRiskParams()
        });
        
        uint256 supplyRate = Core.calculateSupplyRate(input);
        // Supply rate = spreadRate * utilization
        // spreadRate at 80% = 0.02 + 0.04 * 0.8 = 0.052
        // supplyRate = 0.052 * 0.8 = 0.0416 (4.16%)
        uint256 expectedSpread = BASE_SPREAD_RATE + SLOPE1.rayMul(OPTIMAL_UTILIZATION);
        uint256 expected = expectedSpread.rayMul(0.8e27);
        assertApproxEqRel(supplyRate, expected, 0.001e18, "Supply rate should be ~4.16%");
    }
    
    // ============ Index Update Tests ============
    
    function test_UpdateIndices_OneYear() public {
        // Setup initial state
        Storage.ReserveData memory reserve = Storage.ReserveData({
            variableBorrowIndex: RAY, // Start at 1.0
            liquidityIndex: RAY, // Start at 1.0
            totalScaledBorrowed: 80_000e6, // 80k borrowed
            totalBorrowed: 80_000e6,
            totalScaledSupplied: 100_000e6, // 100k supplied
            totalCollateral: 100e18, // 100 prediction tokens
            lastUpdateTimestamp: block.timestamp,
            cachedUtilization: 0.8e27,
            accumulatedSpread: 0,
            accumulatedRedeemed: 0,
            accumulatedReserves: 0
        });
        
        // Fast forward 1 year
        vm.warp(block.timestamp + SECONDS_PER_YEAR);
        
        Core.UpdateIndicesInput memory input = Core.UpdateIndicesInput({
            reserve: reserve,
            riskParams: _getRiskParams()
        });
        
        (uint256 newBorrowIndex, uint256 newLiquidityIndex) = Core.updateIndices(input);
        
        // At 80% utilization, spread rate = 5.2%, supply rate = 4.16%
        // After 1 year: borrowIndex should be ~1.052, liquidityIndex should be ~1.0416
        assertApproxEqRel(newBorrowIndex, 1.052e27, 0.01e18, "Borrow index after 1 year");
        assertApproxEqRel(newLiquidityIndex, 1.0416e27, 0.01e18, "Liquidity index after 1 year");
    }
    
    // ============ Borrow Calculation Tests ============
    
    function test_CalculateBorrowAble() public {
        // Test max borrow calculation with realistic values
        // User deposits 100 prediction tokens worth $0.65 each
        Core.CalcMaxBorrowInput memory input = Core.CalcMaxBorrowInput({
            collateralAmount: 100e18, // 100 prediction tokens
            collateralPrice: 0.65e27, // $0.65 per token
            ltv: LTV, // 60%
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        uint256 maxBorrow = Core.calculateBorrowAble(input);
        // Expected: 100 * 0.65 * 0.6 = 39 USDC
        assertEq(maxBorrow, 39e6, "Should be able to borrow 39 USDC");
    }
    
    function test_CalculateUserTotalDebt() public {
        // Test debt calculation with accrued interest
        Core.CalcUserTotalDebtInput memory input = Core.CalcUserTotalDebtInput({
            principalDebt: 100e6, // 100 USDC principal (from Aave)
            scaledPolynanceSpreadDebtPrincipal: 100e6, // Initial scaled amount
            initialBorrowAmount: 100e6,
            currentPolynanceSpreadBorrowIndex: 1.05e27 // 5% interest accrued
        });
        
        (uint256 totalDebt, uint256 principal, uint256 spreadInterest) = Core.calculateUserTotalDebt(input);
        
        assertEq(principal, 100e6, "Principal should remain 100 USDC");
        assertEq(spreadInterest, 5e6, "Spread interest should be 5 USDC");
        assertEq(totalDebt, 105e6, "Total debt should be 105 USDC");
    }
    
    // ============ Market Resolution Tests ============
    
    function test_MarketResolution_ProfitScenario() public {
        // Scenario: Market resolves favorably, all debts paid, excess distributed
        Core.CalcThreePoolDistributionInput memory input = Core.CalcThreePoolDistributionInput({
            totalCollateralRedeemed: 150_000e6, // 150k USDC redeemed
            aaveCurrentTotalDebt: 80_000e6, // 80k owed to Aave
            accumulatedSpread: 5_000e6, // 5k accumulated spread
            currentBorrowIndex: 1.05e27,
            totalScaledBorrowed: 80_000e6,
            totalNotScaledBorrowed: 80_000e6,
            reserveFactor: RESERVE_FACTOR,
            lpShareOfRedeemed: LP_SHARE_OF_REDEEMED
        });
        
        Core.ThreePoolDistributionResult memory result = Core.calculateThreePoolDistribution(input);
        
        assertEq(result.aaveDebtRepaid, 80_000e6, "Aave should be fully repaid");
        
        // Total spread = 5k + (84k - 80k) = 9k
        // Protocol gets 10% = 900 USDC
        // LPs get 90% of spread = 8.1k USDC
        // Remaining = 150k - 80k - 9k = 61k
        // LPs get 50% of excess = 30.5k
        // Borrowers get 50% of excess = 30.5k
        
        uint256 totalSpread = 9_000e6;
        uint256 protocolShare = totalSpread.percentMul(RESERVE_FACTOR);
        uint256 lpSpreadShare = totalSpread - protocolShare;
        uint256 excess = 61_000e6;
        uint256 lpExcess = excess.percentMul(LP_SHARE_OF_REDEEMED);
        
        assertEq(result.protocolPool, protocolShare, "Protocol pool incorrect");
        assertEq(result.lpSpreadPool, lpSpreadShare + lpExcess, "LP pool incorrect");
        assertEq(result.borrowerPool, excess - lpExcess, "Borrower pool incorrect");
    }
    
    function test_MarketResolution_LossScenario() public {
        // Scenario: Market resolves unfavorably, Aave partially repaid
        Core.CalcThreePoolDistributionInput memory input = Core.CalcThreePoolDistributionInput({
            totalCollateralRedeemed: 50_000e6, // Only 50k USDC redeemed
            aaveCurrentTotalDebt: 80_000e6, // 80k owed to Aave
            accumulatedSpread: 5_000e6,
            currentBorrowIndex: 1.05e27,
            totalScaledBorrowed: 80_000e6,
            totalNotScaledBorrowed: 80_000e6,
            reserveFactor: RESERVE_FACTOR,
            lpShareOfRedeemed: LP_SHARE_OF_REDEEMED
        });
        
        Core.ThreePoolDistributionResult memory result = Core.calculateThreePoolDistribution(input);
        
        assertEq(result.aaveDebtRepaid, 50_000e6, "Aave only gets what's available");
        assertEq(result.protocolPool, 0, "No funds for protocol");
        assertEq(result.lpSpreadPool, 0, "No funds for LPs");
        assertEq(result.borrowerPool, 0, "No funds for borrowers");
    }
    
    function test_MarketResolution_BreakEvenScenario() public {
        // Scenario: Exactly enough to pay Aave and protocol spread
        Core.CalcThreePoolDistributionInput memory input = Core.CalcThreePoolDistributionInput({
            totalCollateralRedeemed: 80_900e6, // Aave debt + protocol spread
            aaveCurrentTotalDebt: 80_000e6,
            accumulatedSpread: 5_000e6,
            currentBorrowIndex: 1.05e27,
            totalScaledBorrowed: 80_000e6,
            totalNotScaledBorrowed: 80_000e6,
            reserveFactor: RESERVE_FACTOR,
            lpShareOfRedeemed: LP_SHARE_OF_REDEEMED
        });
        
        Core.ThreePoolDistributionResult memory result = Core.calculateThreePoolDistribution(input);
        
        assertEq(result.aaveDebtRepaid, 80_000e6, "Aave fully repaid");
        assertEq(result.protocolPool, 900e6, "Protocol gets its 10% of 9k spread");
        assertEq(result.lpSpreadPool, 0, "Nothing left for LP spread");
        assertEq(result.borrowerPool, 0, "Nothing for borrowers");
    }
    
    // ============ LP Claim Calculation Tests ============
    
    function test_CalculateLpClaimAmount() public {
        // Test LP claim calculation with various positions
        Core.CalcLpClaimInput memory input = Core.CalcLpClaimInput({
            scaledSupplyBalance: 10_000e6, // User has 10k scaled balance
            totalScaledSupplied: 100_000e6, // Total 100k scaled supply
            lpSpreadPool: 50_000e6 // 50k USDC in LP pool
        });
        
        uint256 claimAmount = Core.calculateLpClaimAmount(input);
        // User owns 10% of supply, should get 10% of pool = 5k USDC
        assertEq(claimAmount, 5_000e6, "LP should claim 5k USDC");
    }
    
    // ============ Edge Case Tests ============
    
    function test_EdgeCase_ZeroDivision() public {
        // Test all functions with zero denominators
        
        // Zero supply in utilization
        uint256 util = Core.calculateUtilization(100e6, 0);
        assertEq(util, 0, "Should handle zero supply");
        
        // Zero total scaled supply in LP claim
        Core.CalcLpClaimInput memory lpInput = Core.CalcLpClaimInput({
            scaledSupplyBalance: 100e6,
            totalScaledSupplied: 0,
            lpSpreadPool: 1000e6
        });
        uint256 claim = Core.calculateLpClaimAmount(lpInput);
        assertEq(claim, 0, "Should handle zero total supply");
    }
    
    function test_EdgeCase_Overflow() public {
        // Test with maximum realistic values
        uint256 maxSupply = 1_000_000_000e6; // 1 billion USDC
        uint256 maxBorrow = 999_000_000e6; // 999 million USDC
        
        Core.CalcPureSpreadRateInput memory input = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: maxBorrow,
            totalPolynanceSupply: maxSupply,
            riskParams: _getRiskParams()
        });
        
        uint256 spreadRate = Core.calculateSpreadRate(input);
        // Should handle high utilization (99.9%) without overflow
        assertTrue(spreadRate > 0, "Should calculate spread rate for high amounts");
        assertTrue(spreadRate < 2e27, "Spread rate should be reasonable");
    }
    
    // ============ Helper Functions ============
    
    function _getRiskParams() internal view returns (Storage.RiskParams memory) {
        return Storage.RiskParams({
            interestRateMode: InterestRateMode.VARIABLE,
            baseSpreadRate: BASE_SPREAD_RATE,
            optimalUtilization: OPTIMAL_UTILIZATION,
            slope1: SLOPE1,
            slope2: SLOPE2,
            reserveFactor: RESERVE_FACTOR,
            ltv: LTV,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            liquidationCloseFactor: 5000, // 50%
            lpShareOfRedeemed: LP_SHARE_OF_REDEEMED,
            liquidationBonus: 500, // 5%
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
    
    // ============ Fuzz Tests ============
    
    function testFuzz_SpreadRateMonotonicity(uint256 util1, uint256 util2) public {
        util1 = bound(util1, 0, RAY);
        util2 = bound(util2, 0, RAY);
        vm.assume(util1 < util2);
        
        Core.CalcPureSpreadRateInput memory input1 = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: util1,
            totalPolynanceSupply: RAY,
            riskParams: _getRiskParams()
        });
        
        Core.CalcPureSpreadRateInput memory input2 = Core.CalcPureSpreadRateInput({
            totalBorrowedPrincipal: util2,
            totalPolynanceSupply: RAY,
            riskParams: _getRiskParams()
        });
        
        uint256 rate1 = Core.calculateSpreadRate(input1);
        uint256 rate2 = Core.calculateSpreadRate(input2);
        
        assertTrue(rate2 >= rate1, "Spread rate should be monotonically increasing");
    }
    
    function testFuzz_BorrowValidation(uint256 collateral, uint256 price) public {
        collateral = bound(collateral, 1e18, 1_000_000e18); // 1 to 1M tokens
        price = bound(price, 0.01e27, 1e27); // $0.01 to $1
        
        Core.CalcMaxBorrowInput memory input = Core.CalcMaxBorrowInput({
            collateralAmount: collateral,
            collateralPrice: price,
            ltv: LTV,
            supplyAssetDecimals: USDC_DECIMALS,
            collateralAssetDecimals: COLLATERAL_DECIMALS
        });
        
        uint256 maxBorrow = Core.calculateBorrowAble(input);
        uint256 collateralValue = collateral.mulDiv(price, RAY).mulDiv(10**USDC_DECIMALS, 10**COLLATERAL_DECIMALS);
        
        assertTrue(maxBorrow <= collateralValue, "Cannot borrow more than collateral value");
        assertTrue(maxBorrow <= collateralValue.percentMul(LTV), "Must respect LTV");
    }
}