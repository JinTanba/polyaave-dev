// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./Base.t.sol";
import "../src/libraries/Storage.sol";
import "../src/libraries/PolynanceEE.sol";
import "../src/interfaces/ILiquidityLayer.sol";
import "../src/interfaces/Oralce.sol";
import "../src/interfaces/IPositionToken.sol";
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
        return 0.8 * 10**18;
    }
}

// Mock prediction token that implements redemption
contract MockPredictionToken is MockERC20, IPositionToken {
    address public redeemToken; // The token to redeem to (e.g., USDC)
    address public oracle; // How much redeemToken per prediction token
    
    constructor(
        string memory name, 
        string memory symbol, 
        address _redeemToken,
        address _oracle
    ) MockERC20(name, symbol, 18) {
        redeemToken = _redeemToken;
        oracle = _oracle;
    }

    
    function redeem() external override returns (uint256) {
        uint256 balance = balanceOf(msg.sender);

        console.log("Redeeming prediction tokens:", balance, "for", redeemToken);
        //redeemAmount(decimal 6) = balance * N usdc price(like: 0.8 wad)
        uint256 priceWad = 0.8 *10**18; // Example price in 18 decimals (0.3 USDC per prediction token)
        uint256 redeemAmount = (balance * priceWad) / 1e18/1e12; // Convert to 6 decimals for USDC
        console.log(                                                                                            "//////Redeem amount:", redeemAmount);
        // Burn the prediction tokens
        _burn(msg.sender, balance);
        
        // Transfer the redemption tokens
        IERC20(redeemToken).transfer(msg.sender, redeemAmount);
        
        return redeemAmount;
    }
}

contract MarketResolveTest is PolynanceTest {
    PolynanceLendingMarket public polynanceLend;
    MockPredictionToken public predictionAsset;
    MockOracle public oracle;
    Storage.RiskParams public riskParams;

    address internal supplier;
    address internal borrower;
    address internal borrower2;
    address internal curator;
    uint256 internal constant SUPPLY_AMOUNT = 100 * 10**6; // 100 USDC
    uint256 internal constant COLLATERAL_AMOUNT = 100 ether; // 100 prediction tokens
    
    function setUp() public override {
        super.setUp();
        
        // Set up addresses
        supplier = vm.addr(1);
        borrower = vm.addr(2);
        borrower2 = vm.addr(3);
        curator = vm.addr(4);
        
        // Deploy oracle
        oracle = new MockOracle();
        oracle.setPrice(address(predictionAsset), 0.8 * 10**18); // 0.8 USD
        
        // Deploy prediction token that can redeem to USDC
        predictionAsset = new MockPredictionToken(
            "Prediction Token", 
            "PRED", 
            address(USDC),
            address(oracle)
        );
        
        // Transfer tokens to participants
        USDC.transfer(supplier, 1000 * 10**6);
        USDC.transfer(borrower, 200 * 10**6);
        USDC.transfer(borrower2, 200 * 10**6);
        
        // Mint prediction tokens
        predictionAsset.mint(borrower, 1000 ether);
        predictionAsset.mint(borrower2, 1000 ether);
        
        // Give the prediction token contract some USDC for redemptions
        USDC.transfer(address(predictionAsset), 10000 * 10**6);
        
        // Create risk parameters with maturity date
        riskParams = Storage.RiskParams({
            interestRateMode: InterestRateMode.VARIABLE,
            baseSpreadRate: 0.02e27,
            optimalUtilization: 0.8e27,
            slope1: 0.05e27,
            slope2: 1e27,
            reserveFactor: 1000, // 10%
            ltv: 5000, // 50%
            liquidationThreshold: 8000,
            liquidationCloseFactor: 1000,
            liquidationBonus: 500,
            lpShareOfRedeemed: 1000, // 70%
            maturityDate: block.timestamp + 90 days, // 1 h
            priceOracle: address(oracle),
            liquidityLayer: address(0),
            supplyAsset: address(USDC),
            collateralAsset: address(predictionAsset),
            supplyAssetDecimals: 6,
            collateralAssetDecimals: 18,
            curator: curator,
            isActive: true
        });
        
        polynanceLend = new PolynanceLendingMarket(riskParams);
        
        // Set up approvals
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
        
        // Approve prediction token contract to transfer from protocol
        vm.prank(address(polynanceLend));
        predictionAsset.approve(address(polynanceLend), type(uint256).max);
    }

    function supplyLiquidity(uint256 numberOfSupplies) public {
        for (uint256 i = 0; i < numberOfSupplies; i++) {
            vm.prank(supplier);
            polynanceLend.supply(SUPPLY_AMOUNT, riskParams.collateralAsset);
        }
    }

    // function testBasicMarketResolve() public {
    //     // ============ SETUP: Create market activity ============
    //     supplyLiquidity(5);
        
    //     // Borrowers deposit and borrow
    //     vm.prank(borrower);
    //     uint256 borrowed1 = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT, riskParams.collateralAsset);
        
    //     vm.prank(borrower2);
    //     uint256 borrowed2 = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT / 2, riskParams.collateralAsset);
        
    //     // Fast forward some time for interest accrual
    //     vm.warp(block.timestamp + 180 days); // 6 months
        
    //     // ============ PRE-RESOLUTION STATE ============
    //     Storage.ReserveData memory reserveBeforeResolve = polynanceLend.getReserveData(riskParams.collateralAsset);
    //     uint256 aaveDebtBeforeResolve = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
    //     uint256 protocolUSDCBeforeResolve = USDC.balanceOf(address(polynanceLend));
        
    //     assertTrue(reserveBeforeResolve.totalCollateral > 0, "Should have collateral before resolve");
    //     assertTrue(reserveBeforeResolve.totalBorrowed > 0, "Should have borrows before resolve");
    //     assertTrue(aaveDebtBeforeResolve > 0, "Should have Aave debt before resolve");
        
    //     console.log("=== PRE-RESOLUTION STATE ===");
    //     console.log("Total collateral:", reserveBeforeResolve.totalCollateral);
    //     console.log("Total borrowed:", reserveBeforeResolve.totalBorrowed);
    //     console.log("Aave debt:", aaveDebtBeforeResolve);
    //     console.log("Protocol USDC balance:", protocolUSDCBeforeResolve);
        
    //     // ============ RESOLVE MARKET ============
        
    //     // Fast forward to maturity
    //     vm.warp(riskParams.maturityDate + 1 days);
        
    //     // Only curator can resolve
    //     vm.prank(curator);
    //     polynanceLend.resolve(riskParams.collateralAsset);
        
    //     // ============ POST-RESOLUTION STATE ============
    //     Storage.ReserveData memory reserveAfterResolve = polynanceLend.getReserveData(riskParams.collateralAsset);
    //     uint256 aaveDebtAfterResolve = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
    //     uint256 protocolUSDCAfterResolve = USDC.balanceOf(address(polynanceLend));
        
    //     // Check market is resolved and inactive using getter function
    //     Storage.ResolutionData memory resolution = polynanceLend.getResolutionData(riskParams.collateralAsset);
        
    //     assertTrue(resolution.isMarketResolved, "Market should be resolved");
    //     assertEq(resolution.marketResolvedTimestamp, block.timestamp, "Resolution timestamp should be set");
        
    //     // Check Aave debt was repaid (should be less than before)
        
    //     console.log("=== POST-RESOLUTION STATE ===");
    //     console.log("Market resolved:", resolution.isMarketResolved);
    //     console.log("Market active:", riskParams.isActive);
    //     console.log("Aave debt after resolve:", aaveDebtAfterResolve);
    //     console.log("Total collateral redeemed:", resolution.totalCollateralRedeemed);
    //     console.log("LP spread pool:", resolution.lpSpreadPool);
    //     console.log("Borrower pool:", resolution.borrowerPool);
    //     console.log("Protocol pool:", resolution.protocolPool);
    //     console.log("Aave debt repaid:", resolution.aaveDebtRepaid);
    //     console.log("Protocol USDC balance after resolve:", protocolUSDCAfterResolve);
        
    //     // The sum of three pools plus Aave repayment should equal total redeemed
    //     uint256 totalDistributed = resolution.lpSpreadPool + resolution.borrowerPool + resolution.protocolPool + resolution.aaveDebtRepaid;
    //     assertEq(totalDistributed, resolution.totalCollateralRedeemed, "Total distribution should equal redeemed amount");
    // }

    // function testMarketResolveWithDifferentRedemptionValues() public {
    //     supplyLiquidity(2);
        
    //     // Create positions
    //     vm.prank(borrower);
    //     uint256 borrowed = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT, riskParams.collateralAsset);

        
    //     vm.warp(block.timestamp + 90 days);
        
    //     // Test with profitable outcome (1.2 USDC per token)
        
    //     uint256 aaveDebtBefore = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        
    //     vm.warp(riskParams.maturityDate + 1 days);
    //     vm.prank(curator);
    //     polynanceLend.resolve(riskParams.collateralAsset);
        

    //     Storage.ResolutionData memory resolution = polynanceLend.getResolutionData(riskParams.collateralAsset);
        
    //     console.log("=== PROFITABLE OUTCOME ===");
    //     console.log("Redemption ratio: 1.2 USDC per token");
    //     console.log("Total redeemed:", resolution.totalCollateralRedeemed);
    //     console.log("Borrower pool (excess):", resolution.borrowerPool);
    //     console.log("LP spread pool:", resolution.lpSpreadPool);
    //     console.log("protocolPool:", resolution.protocolPool);


    //     console.log("calc?", resolution.totalCollateralRedeemed == resolution.borrowerPool+resolution.lpSpreadPool+ resolution.protocolPool+resolution.aaveDebtRepaid);

    //     assertTrue(resolution.totalCollateralRedeemed == resolution.borrowerPool+resolution.lpSpreadPool+resolution.protocolPool +resolution.aaveDebtRepaid, "Market should be resolved");

    // }

    function testCoreCalculationConsistency() public {
        // ============ SETUP WITH KNOWN VALUES ============
        supplyLiquidity(2); // 200 USDC total liquidity
        
        // Single borrower for predictable calculations
        vm.prank(borrower);
        uint256 borrowed = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT, riskParams.collateralAsset); // 100 prediction tokens

        
        // ============ CAPTURE PRE-RESOLUTION STATE ============
        Storage.ReserveData memory reserveBefore = polynanceLend.getReserveData(riskParams.collateralAsset);
        uint256 aaveDebtBefore = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        
        console.log("=== PRE-RESOLUTION STATE FOR CORE VERIFICATION ===");
        console.log("Total collateral:", reserveBefore.totalCollateral);
        console.log("Total borrowed (not scaled):", reserveBefore.totalBorrowed);
        console.log("Total scaled borrowed:", reserveBefore.totalScaledBorrowed);
        console.log("Variable borrow index:", reserveBefore.variableBorrowIndex);
        console.log("Accumulated spread:", reserveBefore.accumulatedSpread);
        console.log("Aave debt:", aaveDebtBefore);
        
        
        // ============ EXECUTE RESOLUTION ============
        vm.warp(block.timestamp + 99 days); // Fast forward to maturity
        vm.prank(curator);
        polynanceLend.resolve(riskParams.collateralAsset);
        
        // ============ VERIFY ACTUAL MATCHES EXPECTED ============
        Storage.ResolutionData memory actualResolution = polynanceLend.getResolutionData(riskParams.collateralAsset);
        uint256 aaveDebtAfter = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        
        console.log("=== ACTUAL RESOLUTION RESULTS ===");
        console.log("Actual redemption:", actualResolution.totalCollateralRedeemed);
        console.log("Actual Aave repaid:", actualResolution.aaveDebtRepaid);
        console.log("Actual LP pool:", actualResolution.lpSpreadPool);
        console.log("Actual borrower pool:", actualResolution.borrowerPool);
        console.log("Actual protocol pool:", actualResolution.protocolPool);
        console.log("Aave debt reduction:", aaveDebtAfter);
        
        // Verify total distribution equals total redeemed
        uint256 totalDistributed = actualResolution.lpSpreadPool + actualResolution.borrowerPool + 
                                 actualResolution.protocolPool + actualResolution.aaveDebtRepaid;
        assertEq(totalDistributed, actualResolution.totalCollateralRedeemed, "Total distribution mismatch");
    }

    // function testClaimCalculationConsistency() public {
    //     supplyLiquidity(2); // 2 supply positions (token IDs 1, 2)
        
    //     vm.prank(borrower);
    //     uint256 borrowed = polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT, riskParams.collateralAsset);
        
    //     vm.warp(riskParams.maturityDate + 1 days);
    //     vm.prank(curator);
    //     polynanceLend.resolve(riskParams.collateralAsset);
        
    //     // ============ TEST BORROWER CLAIM CALCULATION ============
        
    //     Storage.ResolutionData memory resolution = polynanceLend.getResolutionData(riskParams.collateralAsset);
    //     Storage.ReserveData memory reserve = polynanceLend.getReserveData(riskParams.collateralAsset);
    //     Storage.UserPosition memory borrowerPosition = polynanceLend.getUserPosition(borrower, riskParams.collateralAsset);
        
    //     // Calculate expected borrower claim using Core
    //     uint256 expectedBorrowerClaim = Core.calculateBorrowerClaimAmount(
    //         Core.CalcBorrowerClaimInput({
    //             positionCollateralAmount: borrowerPosition.collateralAmount,
    //             totalCollateral: reserve.totalCollateral,
    //             borrowerPool: resolution.borrowerPool
    //         })
    //     );
        
    //     console.log("=== BORROWER CLAIM VERIFICATION ===");
    //     console.log("Borrower position collateral:", borrowerPosition.collateralAmount);
    //     console.log("Total collateral:", reserve.totalCollateral);
    //     console.log("Borrower pool:", resolution.borrowerPool);
    //     console.log("Expected borrower claim:", expectedBorrowerClaim);
        
    //     // Execute claim and verify
    //     uint256 borrowerUSDCBefore = USDC.balanceOf(borrower);
    //     vm.prank(borrower);
    //     polynanceLend.claimBorrowerPosition(riskParams.collateralAsset);
    //     uint256 actualBorrowerClaim = USDC.balanceOf(borrower) - borrowerUSDCBefore;
        
    //     assertEq(actualBorrowerClaim, expectedBorrowerClaim, "Borrower claim calculation mismatch");
        
    //     // ============ TEST LP CLAIM CALCULATION ============
        
    //     Storage.SupplyPosition memory lpPosition = polynanceLend.getSupplyPosition(1); // First LP token
        
    //     // Calculate expected LP claim using Core
    //     uint256 expectedLpClaim = Core.calculateLpClaimAmount(
    //         Core.CalcLpClaimInput({
    //             scaledSupplyBalance: lpPosition.scaledSupplyBalance,
    //             totalScaledSupplied: reserve.totalScaledSupplied,
    //             lpSpreadPool: resolution.lpSpreadPool
    //         })
    //     );
        
    //     console.log("=== LP CLAIM VERIFICATION ===");
    //     console.log("LP scaled supply balance:", lpPosition.scaledSupplyBalance);
    //     console.log("Total scaled supplied:", reserve.totalScaledSupplied);
    //     console.log("LP spread pool:", resolution.lpSpreadPool);
    //     console.log("Expected LP spread claim:", expectedLpClaim);
        
    //     // Note: LP also gets their share of Aave balance, so total payout > spread claim
    //     uint256 supplierUSDCBefore = USDC.balanceOf(supplier);
    //     vm.prank(supplier);
    //     uint256 totalLpPayout = polynanceLend.claimLpPosition(riskParams.collateralAsset, 1);
    //     uint256 actualLpReceived = USDC.balanceOf(supplier) - supplierUSDCBefore;
        
    //     assertEq(actualLpReceived, totalLpPayout, "LP payout return value mismatch");
    //     assertTrue(totalLpPayout >= expectedLpClaim, "Total LP payout should include spread claim");
        
    //     console.log("Total LP payout:", totalLpPayout);
    //     console.log("LP spread portion:", expectedLpClaim);
    // }

    // function testResolveErrorConditions() public {
    //     supplyLiquidity(3);
        
    //     vm.prank(borrower);
    //     polynanceLend.depositAndBorrow(COLLATERAL_AMOUNT, riskParams.collateralAsset);
        
    //     // Test resolve before maturity
    //     vm.prank(curator);
    //     vm.expectRevert(PolynanceEE.MarketNotMature.selector);
    //     polynanceLend.resolve(riskParams.collateralAsset);
        
    //     // Test resolve by non-curator
    //     vm.warp(riskParams.maturityDate + 1 days);
    //     vm.prank(borrower);
    //     vm.expectRevert(PolynanceEE.NotCurator.selector);
    //     polynanceLend.resolve(riskParams.collateralAsset);
        
    //     // Successful resolve
    //     vm.prank(curator);
    //     polynanceLend.resolve(riskParams.collateralAsset);
        
    //     // Test double resolve
    //     vm.prank(curator);
    //     vm.expectRevert(PolynanceEE.MarketAlreadyResolved.selector);
    //     polynanceLend.resolve(riskParams.collateralAsset);
    // }

    // function testResolveWithNoActivity() public {
    //     // Don't create any positions
        
    //     vm.warp(riskParams.maturityDate + 1 days);
        
    //     vm.prank(curator);
    //     polynanceLend.resolve(riskParams.collateralAsset);
        
    //     Storage.ResolutionData memory resolution = polynanceLend.getResolutionData(riskParams.collateralAsset);
        
    //     assertTrue(resolution.isMarketResolved, "Market should be resolved even with no activity");
    //     assertEq(resolution.totalCollateralRedeemed, 0, "No collateral to redeem");
    //     assertEq(resolution.lpSpreadPool, 0, "No LP pool");
    //     assertEq(resolution.borrowerPool, 0, "No borrower pool");
    //     assertEq(resolution.protocolPool, 0, "No protocol pool");
    // }

    // ============ HELPER FUNCTIONS ============

    function logResolutionState() public view {
        Storage.ResolutionData memory resolution = polynanceLend.getResolutionData(riskParams.collateralAsset);
        
        console.log("=== RESOLUTION STATE ===");
        console.log("Is resolved:", resolution.isMarketResolved);
        console.log("Total redeemed:", resolution.totalCollateralRedeemed);
        console.log("Aave debt repaid:", resolution.aaveDebtRepaid);
        console.log("LP spread pool:", resolution.lpSpreadPool);
        console.log("Borrower pool:", resolution.borrowerPool);
        console.log("Protocol pool:", resolution.protocolPool);
    }
}