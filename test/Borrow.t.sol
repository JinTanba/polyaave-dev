// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./Base.t.sol";
import "../src/libraries/Storage.sol";
import "../src/libraries/PolynanceEE.sol";
import "../src/interfaces/ILiquidityLayer.sol";
import "../src/interfaces/Oralce.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PolynanceLendingMarket} from "../src/PolynanceLend.sol";
import {AaveLibrary} from "../src/adaptor/AaveModule.sol";
import "../src/Core.sol";

// Mock contracts
contract MockERC20 is ERC20 {
    uint8 private _decimals;
    
    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }
    
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockOracle is IOracle {
    mapping(address => uint256) public prices;
    
    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }
    
    function getCurrentPrice(address positionToken) external view returns (uint256) {
        return prices[positionToken];
    }
}

contract BorrowTest is PolynanceTest {
    PolynanceLendingMarket public polynanceLend;
    MockERC20 public predictionAsset;
    MockOracle public oracle;
    Storage.RiskParams public riskParams;

    address internal supplier;
    address internal borrower;
    address internal borrower2;
    uint256 internal constant SUPPLY_AMOUNT = 100 * 10**6; // 100 USDC
    uint256 internal constant COLLATERAL_AMOUNT = 100 ether; // 100 prediction tokens
    
    function setUp() public override {
        super.setUp();
        
        // Deploy mock contracts
        predictionAsset = new MockERC20("Prediction Token", "PRED", 18);
        oracle = new MockOracle();
        oracle.setPrice(address(predictionAsset), 0.8 * 10**18); // 0.8 USD
        
        // Set up addresses
        supplier = vm.addr(1);
        borrower = vm.addr(2);
        borrower2 = vm.addr(3);
        
        // Transfer tokens
        USDC.transfer(supplier, 1000 * 10**6);
        USDC.transfer(borrower, 200 * 10**6);
        USDC.transfer(borrower2, 200 * 10**6);
        predictionAsset.mint(borrower, 1000 ether);
        predictionAsset.mint(borrower2, 1000 ether);
        
        // Create risk parameters
        riskParams = Storage.RiskParams({
            interestRateMode: InterestRateMode.VARIABLE,
            baseSpreadRate: 0.02e27,
            optimalUtilization: 0.8e27,
            slope1: 0.05e27,
            slope2: 1e27,
            reserveFactor: 1000,
            ltv: 5000, // 50%
            liquidationThreshold: 8000,
            liquidationCloseFactor: 1000,
            liquidationBonus: 500,
            lpShareOfRedeemed: 7000,
            maturityDate: block.timestamp + 365 days,
            priceOracle: address(oracle),
            liquidityLayer: address(0),
            supplyAsset: address(USDC),
            collateralAsset: address(predictionAsset),
            supplyAssetDecimals: 6,
            collateralAssetDecimals: 18,
            curator: address(this),
            isActive: true
        });
        
        polynanceLend = new PolynanceLendingMarket(riskParams);
        
        // Approvals
        vm.prank(supplier);
        USDC.approve(address(polynanceLend), type(uint256).max);
        
        vm.prank(borrower);
        predictionAsset.approve(address(polynanceLend), type(uint256).max);
        vm.prank(borrower);
        USDC.approve(address(polynanceLend), type(uint256).max);
        
        vm.prank(borrower2);
        predictionAsset.approve(address(polynanceLend), type(uint256).max);
        vm.prank(borrower2);
        USDC.approve(address(polynanceLend), type(uint256).max);
    }

    function supplyLiquidity(uint256 numberOfSupplies) public {
        for (uint256 i = 0; i < numberOfSupplies; i++) {
            vm.prank(supplier);
            polynanceLend.supply(SUPPLY_AMOUNT, address(predictionAsset));
        }
    }

    // ============ BASIC TESTS ============

    function testDepositAndBorrow() public {
        supplyLiquidity(5);
        
        uint256 usdcBefore = USDC.balanceOf(borrower);
        uint256 collBefore = predictionAsset.balanceOf(borrower);

        vm.prank(borrower);
        uint256 borrowReturned = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT, address(predictionAsset));

        // Check balances changed correctly
        assertEq(predictionAsset.balanceOf(borrower), collBefore - COLLATERAL_AMOUNT, "Collateral not transferred");
        assertEq(USDC.balanceOf(borrower), usdcBefore + borrowReturned, "USDC not received");
        assertTrue(borrowReturned > 0, "Should have borrowed something");
        
        // Check position state
        Storage.UserPosition memory position = polynanceLend.getUserPosition(borrower, address(predictionAsset));
        assertEq(position.collateralAmount, COLLATERAL_AMOUNT, "Position collateral wrong");
        assertEq(position.borrowAmount, borrowReturned, "Position borrow amount wrong");
        assertTrue(position.scaledDebtBalance > 0, "Should have debt");
        
        console.log("Borrowed amount:", borrowReturned);
    }

    function testSeparateDepositThenBorrow() public {
        supplyLiquidity(5);
        
        // First deposit collateral
        vm.prank(borrower);
        polynanceLend.deposit(COLLATERAL_AMOUNT, address(predictionAsset));
        
        // Check position after deposit
        Storage.UserPosition memory pos1 = polynanceLend.getUserPosition(borrower, address(predictionAsset));
        assertEq(pos1.collateralAmount, COLLATERAL_AMOUNT);
        assertEq(pos1.borrowAmount, 0);
        
        // Then borrow max (amount = 0 means max)
        uint256 usdcBefore = USDC.balanceOf(borrower);
        vm.prank(borrower);
        polynanceLend.borrow(0, address(predictionAsset));
        
        uint256 borrowed = USDC.balanceOf(borrower) - usdcBefore;
        assertTrue(borrowed > 0, "Should have borrowed");
        
        // Check final position
        Storage.UserPosition memory pos2 = polynanceLend.getUserPosition(borrower, address(predictionAsset));
        assertEq(pos2.borrowAmount, borrowed);
        assertTrue(pos2.scaledDebtBalance > 0);
    }

    function testBasicRepay() public {
        supplyLiquidity(5);
        
        // Borrow first
        vm.prank(borrower);
        uint256 borrowedAmount = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT, address(predictionAsset));
        
        // Fast forward time to accrue some interest
        vm.warp(block.timestamp + 30 days);
        
        // Check position before repay
        Storage.UserPosition memory posBefore = polynanceLend.getUserPosition(borrower, address(predictionAsset));
        assertTrue(posBefore.borrowAmount > 0, "Should have debt");
        assertTrue(posBefore.collateralAmount > 0, "Should have collateral");
        
        // Calculate total debt (simplified - just use current debt for test)
        Storage.ReserveData memory reserve = polynanceLend.getReserveData(address(predictionAsset));
        uint256 totalDebt = posBefore.borrowAmount + (posBefore.borrowAmount / 100); // Add 1% for interest
        
        uint256 usdcBefore = USDC.balanceOf(borrower);
        uint256 collBefore = predictionAsset.balanceOf(borrower);
        
        // Repay
        vm.prank(borrower);
        uint256 repaidAmount = polynanceLend.repay(address(predictionAsset));
        
        // Check balances after repay
        assertEq(USDC.balanceOf(borrower), usdcBefore - repaidAmount, "USDC not deducted correctly");
        assertEq(predictionAsset.balanceOf(borrower), collBefore + COLLATERAL_AMOUNT, "Collateral not returned");
        
        // Check position is cleared
        Storage.UserPosition memory posAfter = polynanceLend.getUserPosition(borrower, address(predictionAsset));
        assertEq(posAfter.borrowAmount, 0, "Debt not cleared");
        assertEq(posAfter.collateralAmount, 0, "Collateral not cleared");
        assertEq(posAfter.scaledDebtBalance, 0, "Scaled debt not cleared");
        
        console.log("Repaid amount:", repaidAmount);
        console.log("Original borrowed:", borrowedAmount);
    }

    function testMultipleBorrowers() public {
        supplyLiquidity(10);
        
        // Both borrowers borrow
        vm.prank(borrower);
        uint256 borrowed1 = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT, address(predictionAsset));
        
        vm.prank(borrower2);
        uint256 borrowed2 = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT / 2, address(predictionAsset));
        
        assertTrue(borrowed1 > 0, "Borrower 1 should have borrowed");
        assertTrue(borrowed2 > 0, "Borrower 2 should have borrowed");
        assertTrue(borrowed1 > borrowed2, "Borrower 1 should have borrowed more");
        
        // Check both have positions
        Storage.UserPosition memory pos1 = polynanceLend.getUserPosition(borrower, address(predictionAsset));
        Storage.UserPosition memory pos2 = polynanceLend.getUserPosition(borrower2, address(predictionAsset));
        
        assertTrue(pos1.borrowAmount > 0 && pos1.collateralAmount > 0);
        assertTrue(pos2.borrowAmount > 0 && pos2.collateralAmount > 0);
        
        console.log("Borrower 1 borrowed:", borrowed1);
        console.log("Borrower 2 borrowed:", borrowed2);
    }

    // ============ ERROR TESTS ============

    function testBorrowWithoutCollateral() public {
        supplyLiquidity(5);
        
        vm.prank(borrower);
        vm.expectRevert(PolynanceEE.InsufficientCollateral.selector);
        polynanceLend.borrow(1000000, address(predictionAsset));
    }

    function testBorrowWithoutLiquidity() public {
        // Don't supply liquidity
        
        vm.prank(borrower);
        vm.expectRevert();
        polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT, address(predictionAsset));
    }

    function testRepayWithoutDebt() public {
        vm.prank(borrower);
        vm.expectRevert(PolynanceEE.NoDebtToRepay.selector);
        polynanceLend.repay(address(predictionAsset));
    }


    // ============ AAVE DEBT TRACKING TESTS ============

    function testTrackAaveDebtChanges() public {
        supplyLiquidity(5);
        
        // Track initial Aave debt (should be 0)
        uint256 initialAaveDebt = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        assertEq(initialAaveDebt, 0, "Initial Aave debt should be 0");
        
        // Borrower 1 borrows
        vm.prank(borrower);
        uint256 borrowed1 = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT, address(predictionAsset));
        
        // Check Aave debt increased
        uint256 aaveDebtAfterBorrow1 = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        assertTrue(aaveDebtAfterBorrow1 > initialAaveDebt, "Aave debt should increase after first borrow");
        assertTrue(aaveDebtAfterBorrow1 >= borrowed1, "Aave debt should be at least borrowed amount");
        
        console.log("After first borrow - Aave debt:", aaveDebtAfterBorrow1);
        console.log("Borrowed amount:", borrowed1);
        
        // Borrower 2 borrows
        vm.prank(borrower2);
        uint256 borrowed2 = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT / 2, address(predictionAsset));
        
        // Check Aave debt increased further
        uint256 aaveDebtAfterBorrow2 = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        assertTrue(aaveDebtAfterBorrow2 > aaveDebtAfterBorrow1, "Aave debt should increase after second borrow");
        
        console.log("After second borrow - Aave debt:", aaveDebtAfterBorrow2);
        console.log("Second borrowed amount:", borrowed2);
        
        // Fast forward time to accrue interest
        vm.warp(block.timestamp + 30 days);
        
        // Check debt increased due to interest
        uint256 aaveDebtWithInterest = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        assertTrue(aaveDebtWithInterest >= aaveDebtAfterBorrow2, "Aave debt should increase with interest");
        
        console.log("After 30 days - Aave debt with interest:", aaveDebtWithInterest);
        
        vm.prank(borrower);
        polynanceLend.repay(address(predictionAsset));
        
        // Check Aave debt decreased
        uint256 aaveDebtAfterRepay1 = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        assertTrue(aaveDebtAfterRepay1 < aaveDebtWithInterest, "Aave debt should decrease after repay");
        
        console.log("After first repay - Aave debt:", aaveDebtAfterRepay1);
    }

    function testConsistentBorrowRepayBorrowCycle() public {
        supplyLiquidity(10); // Provide plenty of liquidity
        
        // ============ CYCLE 1: Borrow ============
        uint256 initialUSDC = USDC.balanceOf(borrower);
        uint256 initialCollateral = predictionAsset.balanceOf(borrower);
        uint256 initialAaveDebt = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        
        vm.prank(borrower);
        uint256 borrowed1 = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT, address(predictionAsset));
        
        // Verify state after first borrow
        assertEq(USDC.balanceOf(borrower), initialUSDC + borrowed1, "USDC balance after borrow");
        assertEq(predictionAsset.balanceOf(borrower), initialCollateral - COLLATERAL_AMOUNT, "Collateral balance after borrow");
        
        uint256 aaveDebtAfterBorrow1 = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        assertTrue(aaveDebtAfterBorrow1 > initialAaveDebt, "Aave debt should increase");
        
        Storage.UserPosition memory pos1 = polynanceLend.getUserPosition(borrower, address(predictionAsset));
        assertEq(pos1.collateralAmount, COLLATERAL_AMOUNT, "Position collateral after borrow");
        assertEq(pos1.borrowAmount, borrowed1, "Position borrow amount after borrow");
        assertTrue(pos1.scaledDebtBalance > 0, "Should have scaled debt");
        
        console.log("=== CYCLE 1: BORROWED ===");
        console.log("Borrowed amount:", borrowed1);
        console.log("Aave debt:", aaveDebtAfterBorrow1);
        
        // ============ CYCLE 1: Repay ============
        vm.warp(block.timestamp + 60 days); // Accrue some interest
        
        vm.prank(borrower);
        uint256 repaid1 = polynanceLend.repay(address(predictionAsset));

        console.log("========================-   Initial USDC balance:", pos1.borrowAmount);
        console.log("=========================== Repaid amount:", repaid1);
        
        // Verify state after repay
        assertEq(USDC.balanceOf(borrower), initialUSDC + borrowed1 - repaid1, "USDC balance after repay");
        assertEq(predictionAsset.balanceOf(borrower), initialCollateral, "Collateral returned after repay");
        
        uint256 aaveDebtAfterRepay1 = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        assertTrue(aaveDebtAfterRepay1 < aaveDebtAfterBorrow1, "Aave debt should decrease after repay");
        
        Storage.UserPosition memory pos1AfterRepay = polynanceLend.getUserPosition(borrower, address(predictionAsset));
        assertEq(pos1AfterRepay.collateralAmount, 0, "Position collateral cleared after repay");
        assertEq(pos1AfterRepay.borrowAmount, 0, "Position borrow amount cleared after repay");
        assertEq(pos1AfterRepay.scaledDebtBalance, 0, "Scaled debt cleared after repay");
        
        console.log("=== CYCLE 1: REPAID ===");
        console.log("Repaid amount:", repaid1);
        console.log("Interest paid:", repaid1 - borrowed1);
        console.log("Aave debt after repay:", aaveDebtAfterRepay1);
        
        // ============ CYCLE 2: Borrow Again ============
        uint256 usdcBeforeCycle2 = USDC.balanceOf(borrower);
        uint256 collateralBeforeCycle2 = predictionAsset.balanceOf(borrower);
        
        vm.prank(borrower);
        uint256 borrowed2 = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT * 3 / 4, address(predictionAsset)); // Borrow with less collateral
        
        // Verify state after second borrow
        assertEq(USDC.balanceOf(borrower), usdcBeforeCycle2 + borrowed2, "USDC balance after second borrow");
        assertEq(predictionAsset.balanceOf(borrower), collateralBeforeCycle2 - (COLLATERAL_AMOUNT * 3 / 4), "Collateral balance after second borrow");
        
        uint256 aaveDebtAfterBorrow2 = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        assertTrue(aaveDebtAfterBorrow2 > aaveDebtAfterRepay1, "Aave debt should increase again");
        
        Storage.UserPosition memory pos2 = polynanceLend.getUserPosition(borrower, address(predictionAsset));
        assertEq(pos2.collateralAmount, COLLATERAL_AMOUNT * 3 / 4, "Position collateral after second borrow");
        assertEq(pos2.borrowAmount, borrowed2, "Position borrow amount after second borrow");
        assertTrue(pos2.scaledDebtBalance > 0, "Should have scaled debt again");
        
        // Should borrow less with less collateral
        assertTrue(borrowed2 < borrowed1, "Should borrow less with less collateral");
        
        console.log("=== CYCLE 2: BORROWED AGAIN ===");
        console.log("Borrowed amount:", borrowed2);
        console.log("Aave debt:", aaveDebtAfterBorrow2);
        
        // ============ FINAL VERIFICATION ============
        // Check that reserve state is consistent
        Storage.ReserveData memory finalReserve = polynanceLend.getReserveData(address(predictionAsset));
        assertEq(finalReserve.totalCollateral, COLLATERAL_AMOUNT * 3 / 4, "Reserve total collateral should match position");
        assertEq(finalReserve.totalBorrowed, borrowed2, "Reserve total borrowed should match position");
        assertTrue(finalReserve.totalScaledBorrowed > 0, "Reserve should have scaled borrowed amount");
        
        console.log("=== FINAL STATE ===");
        console.log("Total cycles completed: 2");
        console.log("Final Aave debt:", aaveDebtAfterBorrow2);
        console.log("Final reserve total borrowed:", finalReserve.totalBorrowed);
        console.log("Final reserve total collateral:", finalReserve.totalCollateral);
    }

    function testStateConsistencyAfterOperations() public {
        supplyLiquidity(5);
        
        // Get initial state
        Storage.ReserveData memory initialReserve = polynanceLend.getReserveData(address(predictionAsset));
        uint256 initialAaveDebt = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        uint256 initialAaveBalance = AaveLibrary.getATokenBalance(address(USDC), address(polynanceLend));
        
        // Perform borrow
        vm.prank(borrower);
        uint256 borrowedAmount = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT, address(predictionAsset));
        
        // Check state consistency after borrow
        Storage.ReserveData memory reserveAfterBorrow = polynanceLend.getReserveData(address(predictionAsset));
        uint256 aaveDebtAfterBorrow = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        uint256 aaveBalanceAfterBorrow = AaveLibrary.getATokenBalance(address(USDC), address(polynanceLend));
        
        // Verify reserve changes
        assertEq(reserveAfterBorrow.totalCollateral, initialReserve.totalCollateral + COLLATERAL_AMOUNT, "Reserve collateral should increase");
        assertEq(reserveAfterBorrow.totalBorrowed, initialReserve.totalBorrowed + borrowedAmount, "Reserve borrowed should increase");
        
        // Verify Aave changes
        assertTrue(aaveDebtAfterBorrow > initialAaveDebt, "Aave debt should increase");
        assertTrue(aaveBalanceAfterBorrow >= initialAaveBalance, "Aave balance should not decrease"); // Supply happened first
        
        // The borrowed amount should have been transferred from Aave balance to user
        // So the net effect on Aave should be that debt increased by borrowedAmount
        assertTrue(aaveDebtAfterBorrow - initialAaveDebt >= borrowedAmount * 99 / 100, "Debt increase should approximately equal borrowed amount");
        
        console.log("=== STATE CONSISTENCY CHECK ===");
        console.log("Borrowed from user perspective:", borrowedAmount);
        console.log("Aave debt increase:", aaveDebtAfterBorrow - initialAaveDebt);
        console.log("Reserve total borrowed:", reserveAfterBorrow.totalBorrowed);
        console.log("Reserve total collateral:", reserveAfterBorrow.totalCollateral);
        
        // Verify that internal accounting matches external reality
        assertApproxEqRel(reserveAfterBorrow.totalBorrowed, aaveDebtAfterBorrow - initialAaveDebt, 0.05e18, "Internal and external debt should roughly match");
    }

    // ============ HELPER FUNCTIONS ============

    function getBorrowingCapacity(address user) public view returns (uint256) {
        return polynanceLend.getBorrowingCapacity(user, address(predictionAsset));
    }

    function logPositionState(address user, string memory label) public view {
        Storage.UserPosition memory pos = polynanceLend.getUserPosition(user, address(predictionAsset));
        console.log(label);
        console.log("  Collateral:", pos.collateralAmount);
        console.log("  Borrow Amount:", pos.borrowAmount);
        console.log("  Scaled Debt:", pos.scaledDebtBalance);
    }

    function logReserveState() public view {
        Storage.ReserveData memory reserve = polynanceLend.getReserveData(address(predictionAsset));
        console.log("Reserve State:");
        console.log("  Total Collateral:", reserve.totalCollateral);
        console.log("  Total Borrowed:", reserve.totalBorrowed);
        console.log("  Total Scaled Borrowed:", reserve.totalScaledBorrowed);
        console.log("  Borrow Index:", reserve.variableBorrowIndex);
        console.log("  Liquidity Index:", reserve.liquidityIndex);
    }

    function logAaveState() public view {
        uint256 aaveDebt = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        uint256 aaveBalance = AaveLibrary.getATokenBalance(address(USDC), address(polynanceLend));
        console.log("Aave State:");
        console.log("  Protocol debt to Aave:", aaveDebt);
        console.log("  Protocol aToken balance:", aaveBalance);
    }
}