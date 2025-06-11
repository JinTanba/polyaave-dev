 // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./Base.t.sol";
import "../src/libraries/Storage.sol";
import "../src/libraries/PolynanceEE.sol";
import "../src/interfaces/ILiquidityLayer.sol";
import "../src/interfaces/Oralce.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PolynanceLendingMarket} from "../src/PolynanceLend.sol";
import {AaveModule} from "../src/adaptor/AaveModule.sol";
import {IPositionToken} from "../src/interfaces/IPositionToken.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/protocol/libraries/math/PercentageMath.sol";

// Mock contracts for testing
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

contract SupplyTest is PolynanceTest {
    PolynanceLendingMarket public polynanceLend;
    MockERC20 public predictionAsset;
    AaveModule public aaveModule;
    MockOracle public oracle;
    Storage.RiskParams public riskParams;
    
    
    address internal supplier;
    uint256 internal constant SUPPLY_AMOUNT = 100 * 10**6; // 100 USDC
    
    function setUp() public override {
        super.setUp();
        console.log("======= Suppy Test =======");
        // Deploy mock contracts
        predictionAsset = new MockERC20("Prediction Token", "PRED", 18);
        oracle = new MockOracle();
        console.log("1. Prediction Asset: ", address(predictionAsset));
        console.log("Oracle: ", address(oracle));
        
        // Set up supplier
        supplier = vm.addr(1);
        console.log("2. Supplier: ", supplier);
        
        // Transfer USDC from base test setup to supplier
        USDC.transfer(supplier, 500 * 10**6); // 500 USDC
        predictionAsset.mint(supplier, 1000 ether);
        console.log("3. Supplier USDC balance: ", USDC.balanceOf(supplier));
        console.log("Supplier predictionAsset balance: ", predictionAsset.balanceOf(supplier));
        
        // Set prediction token price
        oracle.setPrice(address(predictionAsset), 0.8 * 10**18); // 1 USD in Ray format
        console.log("4. Prediction token price: ", oracle.getCurrentPrice(address(predictionAsset)));
        
        // Deploy AaveModule with USDC
        address[] memory assets = new address[](1);
        assets[0] = address(USDC);
        aaveModule = new AaveModule(assets);

        console.log("5. AaveModule: ", address(aaveModule));
        
        // Create risk parameters
        riskParams = Storage.RiskParams({
            interestRateMode: InterestRateMode.VARIABLE,
            baseSpreadRate: 0.02e27, // 2% in bps
            optimalUtilization: 0.8e27, // 80% in bps
            slope1: 0.05e27, // 5% in bps
            slope2: 1e27, // 100% in bps
            reserveFactor: 1000, // 10% in bps
            ltv: 7500, // 75% in bps
            liquidationThreshold: 8000, // 80% in bps
            liquidationCloseFactor: 1000, // 10% in basis points
            liquidationBonus: 500, // 5% in basis points
            lpShareOfRedeemed: 7000, // 70% in basis points
            maturityDate: block.timestamp + 365 days,
            priceOracle: address(oracle),
            liquidityLayer: address(aaveModule),
            supplyAsset: address(USDC),
            supplyAssetDecimals: 6,
            collateralAssetDecimals: 18,
            curator: address(this),
            isActive: true
        });
        
        // Deploy PolynanceLend
        polynanceLend = new PolynanceLendingMarket(riskParams);
        console.log("6. PolynanceLend: ", address(polynanceLend));
        
        // Approve spending
        vm.prank(supplier);
        USDC.approve(address(polynanceLend), type(uint256).max);
        console.log("7. USDC approved");
    }

    function testSupplyBasic() public {
        uint256 numberOfSupplies = 3; // Number of times to supply
        console.log("testSupplyBasic with", numberOfSupplies, "supplies");
        console.log("1. Supplier balance before supply: ", USDC.balanceOf(supplier));
        uint256 supplyBalanceBefore = aaveModule.getSupplyBalance(address(USDC), address(polynanceLend));
        console.log("2. Supply balance before supply: ", supplyBalanceBefore);
        
        // Get initial balances
        uint256 supplierBalanceBefore = USDC.balanceOf(supplier);
        
        // Perform multiple supply operations using a for loop
        for (uint256 i = 1; i <= numberOfSupplies; i++) {
            console.log("Supply operation #", i);
            vm.prank(supplier);
            polynanceLend.supply(SUPPLY_AMOUNT, address(predictionAsset));
            
            // Check that position token was created for this supply
            IERC721 positionToken = IERC721(address(polynanceLend));
            assertEq(positionToken.ownerOf(i), supplier, string(abi.encodePacked("Position token ", i, " should be owned by supplier")));
            console.log("Position token ID created: ", i);
        }
        
        // Check final balances after all supplies
        assertEq(USDC.balanceOf(supplier), supplierBalanceBefore - (SUPPLY_AMOUNT * numberOfSupplies), "Supplier balance after all supplies should decrease by total supplied amount");
        
        uint256 supplyBalance = aaveModule.getSupplyBalance(address(USDC), address(polynanceLend));
        console.log("2. Total supplyBalance: ", supplyBalance);
        
        require(supplyBalance - supplyBalanceBefore >= SUPPLY_AMOUNT * numberOfSupplies, "Total supply balance should equal all supplied amounts");

        //ReserveData
        Storage.ReserveData memory reserve = polynanceLend.getReserveData(address(predictionAsset));
        console.log("FINAL OUTPUT: liquidityIndex", reserve.liquidityIndex);
        console.log("   variableBorrowIndex", reserve.variableBorrowIndex);
        console.log("   totalScaledSupplied", reserve.totalScaledSupplied);
        console.log("   lastUpdateTimestamp", reserve.lastUpdateTimestamp);
        console.log("   totalScaledBorrowed", reserve.totalScaledBorrowed);
    }

    

}