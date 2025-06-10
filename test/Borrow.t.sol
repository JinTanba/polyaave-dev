// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./Base.t.sol";
import "../src/libraries/Storage.sol";
import "../src/libraries/PolynanceEE.sol";
import "../src/interfaces/ILiquidityLayer.sol";
import "../src/interfaces/Oralce.sol"; // Note: Typo in original, should be Oracle.sol if that's the filename
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PolynanceLendingMarket} from "../src/PolynanceLend.sol";
import {AaveLibrary} from "../src/adaptor/AaveModule.sol";
import {IPositionToken} from "../src/interfaces/IPositionToken.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/protocol/libraries/math/PercentageMath.sol";
import "../src/Core.sol";

// (Mock contracts remain the same)
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
    
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
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
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    address internal supplier;
    address internal borrower;
    uint256 internal constant SUPPLY_AMOUNT = 100 * 10**6; // 100 USDC
    
    // (setUp function remains the same)
    function setUp() public override {
        super.setUp();
        // Deploy mock contracts
        predictionAsset = new MockERC20("Prediction Token", "PRED", 18);
        oracle = new MockOracle();
        
        // Set up supplier
        supplier = vm.addr(1);
        
        // Transfer USDC from base test setup to supplier
        USDC.transfer(supplier, 500 * 10**6); // 500 USDC
        // Mint prediction tokens to borrower
        borrower = vm.addr(2);
        predictionAsset.mint(borrower, 1000 ether);

        
        // Set prediction token price
        oracle.setPrice(address(predictionAsset), 0.8 * 10**18); // 1 USD in Ray format
        

        // Create risk parameters
        riskParams = Storage.RiskParams({
            interestRateMode: InterestRateMode.VARIABLE,
            baseSpreadRate: 0.02e27, // 2% in bps
            optimalUtilization: 0.8e27, // 80% in bps
            slope1: 0.05e27, // 5% in bps
            slope2: 1e27, // 100% in bps
            reserveFactor: 1000, // 10% in bps
            ltv: 5000, // 75% in bps
            liquidationThreshold: 8000, // 80% in bps
            liquidationCloseFactor: 1000, // 10% in basis points
            liquidationBonus: 500, // 5% in basis points
            lpShareOfRedeemed: 7000, // 70% in basis points
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
        
        // Deploy PolynanceLend
        polynanceLend = new PolynanceLendingMarket(riskParams);
        
        // Approve spending
        vm.prank(supplier);
        USDC.approve(address(polynanceLend), type(uint256).max);

        // Set borrower
        console.log("Approve borrower: ", borrower);
        vm.prank(borrower);
        predictionAsset.approve(address(polynanceLend), type(uint256).max);
    }

    // (supplyBasic function remains the same)
    function supplyBasic(uint256 numberOfSupplies) public {
        for (uint256 i = 0; i <= numberOfSupplies; i++) {
            // console.log("Supply operation #", i);
            vm.prank(supplier);
            polynanceLend.supply(SUPPLY_AMOUNT, riskParams.collateralAsset);
        }
    }

    function testDeposit() public {
        supplyBasic(1);
        consoleReserveAndPosition();
        vm.startPrank(borrower);
        polynanceLend.deposit(10 ether, riskParams.collateralAsset);
        polynanceLend.borrow(0, riskParams.collateralAsset);
        vm.stopPrank();
        console.log("Borrowed amount: ", polynanceLend.getUserPosition(borrower, riskParams.collateralAsset).borrowAmount);
        consoleReserveAndPosition();
    }

    function testDepositAndBorrowc() public {
        // ---------- 0. Prepare LP liquidity ----------
        supplyBasic(1);

        // ---------- 1. Set up collateral & compute expected borrow ----------
        uint256 collateralAmount = 100 ether;
        consoleReserveAndPosition();
        uint256 usdcBefore = USDC.balanceOf(borrower);
        uint256 collBefore = predictionAsset.balanceOf(borrower);

        vm.startPrank(borrower);
        uint256 borrowReturned = polynanceLend.depositAndBorrow(collateralAmount, riskParams.collateralAsset);
        vm.stopPrank();

        assertEq(predictionAsset.balanceOf(borrower), collBefore - collateralAmount, "Collateral bal mismatch");
        assertEq(USDC.balanceOf(borrower), usdcBefore + borrowReturned, "USDC bal mismatch");
        uint256 contractBalance = predictionAsset.balanceOf(address(polynanceLend));
        assertEq(contractBalance ,collateralAmount, "Contract balance mismatch");
        consoleReserveAndPosition();
        uint256 totalDebt = AaveLibrary.getTotalDebtBase(address(USDC), address(polynanceLend));
        assertTrue(totalDebt >= borrowReturned, "Total debt mismatch");
        
    }

    function _computeExpectedBorrow(uint256 collateralAmount)
        private
        view
        returns (uint256 expectedBorrow)
    {
        uint256 priceRay = (0.8e18);
        Core.CalcMaxBorrowInput memory maxInput = Core.CalcMaxBorrowInput({
            collateralAmount: collateralAmount,
            collateralPrice: priceRay.wadToRay(),
            ltv: riskParams.ltv,
            supplyAssetDecimals: riskParams.supplyAssetDecimals,
            collateralAssetDecimals: riskParams.collateralAssetDecimals
        });
        expectedBorrow = Core.calculateBorrowAble(maxInput);
    }

    function consoleReserveAndPosition() public view returns (Storage.ReserveData memory reserve) {
        reserve = polynanceLend.getReserveData(riskParams.collateralAsset);
        console.log("@Reserve: ");
        console.log("   Reserve Collateral: ", reserve.totalCollateral);
        console.log("   Reserve Borrowed: ", reserve.totalBorrowed);
        console.log("   Reserve Scaled Borrowed: ", reserve.totalScaledBorrowed);
        console.log("   Reserve Variable Borrow Index: ", reserve.variableBorrowIndex);
        console.log("   Reserve Liquidity Index: ", reserve.liquidityIndex);
        console.log("   Reserve Last Update Timestamp: ", reserve.lastUpdateTimestamp);
        console.log("   Reserve Total Scaled Supplied: ", reserve.totalScaledSupplied);

        Storage.UserPosition memory position = polynanceLend.getUserPosition(borrower, riskParams.collateralAsset);
        console.log("@Position: ");
        console.log("   Position Collateral Amount: ", position.collateralAmount);
        console.log("   Position Borrow Amount: ", position.borrowAmount);
        console.log("   Position Scaled Debt Balance: ", position.scaledDebtBalance);
        // console.log("   Position Debt Balance: ", position.scaledDebtBalance.rayMul(reserve.variableBorrowIndex));
    }

}