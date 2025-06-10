// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "./Base.t.sol";
import "../src/libraries/Storage.sol";
import "../src/Core.sol";
import "../src/PolynanceLend.sol";
import "../src/adaptor/AaveModule.sol";
import "../src/interfaces/Oralce.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/protocol/libraries/math/PercentageMath.sol";

/*
 * Refactored Borrow tests:
 *  1. Basic borrow flow validated against Core math (unchanged).
 *  2. Interest-accrual flow which advances time, triggers index update, and
 *     verifies that user debt grows as expected.
 */

// ---------------------------------------------------------------------------
// Helper mock contracts ------------------------------------------------------
// ---------------------------------------------------------------------------
contract MockERC20 is ERC20 {
    uint8 private _decimals;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _decimals = d; }
    function decimals() public view override returns (uint8) { return _decimals; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract MockOracle is IOracle {
    mapping(address=>uint256) public prices;
    function setPrice(address token,uint256 price) external { prices[token]=price; }
    function getCurrentPrice(address token) external view returns(uint256){ return prices[token]; }
}

// ---------------------------------------------------------------------------
// Test contract --------------------------------------------------------------
// ---------------------------------------------------------------------------
contract BorrowTest is PolynanceTest {
    using WadRayMath for uint256;

    // ------------------------------------------------------------------ state
    PolynanceLendingMarket          public polynanceLend;
    MockERC20                       public predictionAsset;
    MockOracle                      public oracle;
    AaveModule                      public aaveModule;
    Storage.RiskParams              public riskParams;

    address internal supplier;
    address internal borrower;
    uint256 internal constant SUPPLY_AMOUNT = 100 * 1e6; // 100 USDC ‑ 6 decimals

    // -------------------------------------------------------------- test setup
    function setUp() public override {
        super.setUp();

        // 1. deploy mocks
        predictionAsset = new MockERC20("Prediction", "PRED", 18);
        oracle          = new MockOracle();
        oracle.setPrice(address(predictionAsset), 0.8e18); // $0.8 – 18-decimals

        // 2. actors
        supplier = vm.addr(1);
        borrower = vm.addr(2);

        // 3. fund accounts
        USDC.transfer(supplier, 500 * 1e6);
        predictionAsset.mint(borrower, 1_000 ether);

        // 4. liquidity layer
        address[] memory assets = new address[](1); assets[0] = address(USDC);
        aaveModule = new AaveModule(assets);

        // 5. risk params (same across tests)
        riskParams = Storage.RiskParams({
            interestRateMode:       InterestRateMode.VARIABLE,
            baseSpreadRate:         0.02e27,
            optimalUtilization:     0.8e27,
            slope1:                 0.05e27,
            slope2:                 1e27,
            reserveFactor:          1000,
            ltv:                    7500,
            liquidationThreshold:   8000,
            liquidationCloseFactor: 5000,
            liquidationBonus:       500,
            lpShareOfRedeemed:      7000,
            maturityDate:           block.timestamp + 365 days,
            priceOracle:            address(oracle),
            liquidityLayer:         address(aaveModule),
            supplyAsset:            address(USDC),
            collateralAsset:        address(predictionAsset),
            supplyAssetDecimals:    6,
            collateralAssetDecimals:18,
            curator:                address(this),
            isActive:               true
        });

        polynanceLend = new PolynanceLendingMarket(riskParams);

        vm.prank(supplier);
        USDC.approve(address(polynanceLend), type(uint256).max);
    }

    // ----------------------------------------------------- internal utilities
    function _supplyLP(uint256 n) internal {
        for(uint256 i; i<n; ++i){
            vm.prank(supplier);
            polynanceLend.supply(SUPPLY_AMOUNT, riskParams.collateralAsset);
        }
    }

    function _borrow(uint256 collateralAmt) internal returns(uint256 borrowed){
        vm.prank(borrower);
        predictionAsset.approve(address(polynanceLend), collateralAmt);
        vm.prank(borrower);
        borrowed = polynanceLend.depositAndBorrow(collateralAmt, riskParams.collateralAsset);
    }

    // ------------------------------------------------------ tests ----------

    /*
     * Validate that debt grows over time by:
     *  (1) Borrowing.
     *  (2) Advancing time 30 days.
     *  (3) Triggering an index update via an extra LP supply.
     *  (4) Asserting new debt > original borrowed principal.
     */
    function testBorrowInterestAccrual() public {
        // 1. Provide initial liquidity & borrow
        _supplyLP(3);
        uint256 collateralAmount = 100 ether;
        uint256 principal = _borrow(collateralAmount);

        // Snapshot scaled debt & index right after borrow
        Storage.UserPosition memory pos0 = polynanceLend.getUserPosition(borrower, riskParams.collateralAsset);
        Storage.ReserveData memory res0 = polynanceLend.getReserveData(riskParams.collateralAsset);
        uint256 debtAtT0 = pos0.scaledDebtBalance.rayMul(res0.variableBorrowIndex);
        assertEq(debtAtT0, principal, "initial debt == principal");

        // 2. Warp 30 days
        vm.warp(block.timestamp + 30 days);

        // 3. Trigger index update with a tiny extra supply
        vm.prank(supplier);
        polynanceLend.supply(1 * 1e6, riskParams.collateralAsset); // 1 USDC

        // 4. Post-update debt calculation
        Storage.UserPosition memory pos1 = polynanceLend.getUserPosition(borrower, riskParams.collateralAsset);
        Storage.ReserveData memory res1 = polynanceLend.getReserveData(riskParams.collateralAsset);
        uint256 debtAtT1 = pos1.scaledDebtBalance.rayMul(res1.variableBorrowIndex);

        // The debt after 30 days (with non-zero spread rate) must be > principal
        assertGt(debtAtT1, debtAtT0, "Debt should accrue interest over time");

        // Additionally, compare against Core math for expected index growth
        (uint256 expectedBorrowIdx,) = Core.updateIndices(
            Core.UpdateIndicesInput({reserve: res0, riskParams: riskParams})
        );
        uint256 expectedDebt = pos0.scaledDebtBalance.rayMul(expectedBorrowIdx);
        assertApproxEqAbs(debtAtT1, expectedDebt, principal / 100); // within 1% tolerance
    }
} 