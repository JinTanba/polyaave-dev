// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/adaptor/AaveModule.sol";
import "../src/interfaces/ILiquidityLayer.sol"; // For InterestRateMode enum via Storage.sol
import "../src/PolynanceLend.sol";

// Minimal WETH/WMATIC interface (inherits IERC20 from AaveModule.sol's imports)
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}


contract AaveInteractionTest is Test {
    using PercentageMath for uint256;
    using WadRayMath for uint256;
    // Configuration
    string constant ENV_POLYGON_RPC_URL = "https://polygon-mainnet.g.alchemy.com/v2/cidppsnxqV4JafKXVW7qd9N2x6wTvTpN";
    uint256 constant FORK_BLOCK_NUMBER = 72384249;

    // Polygon Mainnet Addresses
    IPool constant AAVE_POOL = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IPoolDataProvider constant AAVE_PROTOCOL_DATA_PROVIDER = IPoolDataProvider(0x14496b405D62c24F91f04Cda1c69Dc526D56fDE5);
    IWETH constant WMATIC = IWETH(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);
    IERC20 constant USDC = IERC20(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359); // USDC on Polygon has 6 decimals

    // Instance of your module
    AaveModule internal aaveModule;
    

    // Test parameters
    uint256 constant INITIAL_MATIC_BALANCE = 2100 ether; // MATIC for the test contract
    uint256 constant WMATIC_TO_SUPPLY_DIRECT = 1500 ether;    // Amount of WMATIC to supply directly to Aave in test_ProcureUSDC_FromAave
    uint256 constant USDC_TO_BORROW_DIRECT = 150 * 1e6;    // 150 USDC for test_ProcureUSDC_FromAave

    function setUp() public {
        string memory polygonRpcUrl = ENV_POLYGON_RPC_URL;
        require(bytes(polygonRpcUrl).length > 0, "POLYGON_RPC_URL not set");
        
        vm.createSelectFork(polygonRpcUrl, FORK_BLOCK_NUMBER);

        // Give the test contract some MATIC
        vm.deal(address(this), INITIAL_MATIC_BALANCE);

        aaveModule = new AaveModule();
        vm.label(address(aaveModule), "AaveModule_Instance");
        aaveModule.init(address(USDC));
        aaveModule.init(address(WMATIC));
        USDC.approve(address(aaveModule), type(uint256).max);
        WMATIC.approve(address(aaveModule), type(uint256).max);
    }

    function test_ProcureUSDC_FromAave_Directly() public {
        // --- 1. Obtain WMATIC ---
        console.log("Initial MATIC balance (test contract):", address(this).balance / 1 ether, "MATIC");
        require(address(this).balance >= WMATIC_TO_SUPPLY_DIRECT, "Insufficient MATIC to wrap");

        WMATIC.deposit{value: WMATIC_TO_SUPPLY_DIRECT}();
        assertEq(WMATIC.balanceOf(address(this)), WMATIC_TO_SUPPLY_DIRECT, "WMATIC balance mismatch after deposit");
        console.log("WMATIC balance after wrapping:", WMATIC.balanceOf(address(this)) / 1 ether, "WMATIC");

        // --- 2. Supply WMATIC to Aave V3 Pool Directly ---
        assertTrue(WMATIC.approve(address(AAVE_POOL), WMATIC_TO_SUPPLY_DIRECT), "WMATIC approve for AAVE_POOL failed");
        
        console.log("Supplying", WMATIC_TO_SUPPLY_DIRECT / 1 ether, "WMATIC directly to Aave Pool...");
        AAVE_POOL.supply(address(WMATIC), WMATIC_TO_SUPPLY_DIRECT, address(this), 0);
        
        assertEq(WMATIC.balanceOf(address(this)), 0, "WMATIC balance should be zero after supplying all of it");
        console.log("WMATIC supplied directly. Test contract WMATIC balance:", WMATIC.balanceOf(address(this)) / 1 ether);

        // --- 3. Borrow USDC from Aave V3 Pool Directly ---
        uint256 usdcBalanceBeforeBorrow = USDC.balanceOf(address(this));
        console.log("USDC balance before direct borrow:", usdcBalanceBeforeBorrow / 1e6, "USDC");

        console.log("Attempting to borrow", USDC_TO_BORROW_DIRECT / 1e6, "USDC directly from Aave Pool...");
        AAVE_POOL.borrow(address(USDC), USDC_TO_BORROW_DIRECT, 2, 0, address(this)); // Mode 2 for Variable

        uint256 usdcBalanceAfterBorrow = USDC.balanceOf(address(this));
        console.log("USDC balance after direct borrow:", usdcBalanceAfterBorrow / 1e6, "USDC");
        assertEq(usdcBalanceAfterBorrow, usdcBalanceBeforeBorrow + USDC_TO_BORROW_DIRECT, "USDC balance mismatch after direct borrow");
        console.log("Successfully borrowed USDC directly.");
    }

    function test_AaveModule_SupplyWMATIC_BorrowUSDC() public {
        console.log("--- Testing AaveModule: Supply WMATIC & Borrow USDC ---");

        uint256 wmaticToSupplyForModule = 5000 ether;
        uint256 usdcToBorrowFromModule = 50 * 1e6; // 50 USDC
        vm.deal(address(this), wmaticToSupplyForModule);

        // --- 1. Ensure test contract has MATIC and Wrap to WMATIC ---
        // Test contract should have INITIAL_MATIC_BALANCE - WMATIC_TO_SUPPLY_DIRECT if previous test ran.
        // For robust independent test, ensure enough MATIC here or deal more.
        if (address(this).balance < wmaticToSupplyForModule) {
             vm.deal(address(this), wmaticToSupplyForModule - address(this).balance); // Top up MATIC if needed
        }
        require(address(this).balance >= wmaticToSupplyForModule, "Insufficient MATIC to wrap for module test");
        
        uint256 wmaticBalanceBeforeModuleSupply = WMATIC.balanceOf(address(this));
        WMATIC.deposit{value: wmaticToSupplyForModule}();
        assertEq(WMATIC.balanceOf(address(this)), wmaticBalanceBeforeModuleSupply + wmaticToSupplyForModule, "WMATIC balance mismatch after deposit for module test");
        console.log("WMATIC balance for module test before supply:", WMATIC.balanceOf(address(this)) / 1 ether, "WMATIC");

        // --- 2. Approve AaveModule to spend WMATIC ---
        assertTrue(WMATIC.approve(address(aaveModule), wmaticToSupplyForModule), "WMATIC approve for AaveModule failed");
        uint256 allowance = WMATIC.allowance(address(this), address(aaveModule));
        assertEq(allowance, wmaticToSupplyForModule, "AaveModule WMATIC allowance incorrect");

        // --- 3. Supply WMATIC via AaveModule ---
        console.log("Supplying", wmaticToSupplyForModule / 1 ether, "WMATIC via AaveModule...");
        uint256 initialATokenBalanceModule = aaveModule.getSupplyBalance(address(WMATIC), address(aaveModule));
        assertEq(initialATokenBalanceModule, 0, "Initial aToken balance for module should be 0");
        uint256 initialATokenBalanceTestContract = aaveModule.getSupplyBalance(address(WMATIC), address(this));
        assertEq(initialATokenBalanceTestContract, 0, "Initial aToken balance for test contract should be 0");

        //transfer to module
        uint256 scaledSuppliedAmount = aaveModule.supply(address(WMATIC), wmaticToSupplyForModule, address(this));
        assertTrue(scaledSuppliedAmount > 0, "Scaled supplied amount via module should be greater than 0");
        
        assertEq(WMATIC.balanceOf(address(this)), wmaticBalanceBeforeModuleSupply, "WMATIC balance should revert to pre-deposit state for this test portion after supplying via AaveModule");
        console.log("WMATIC supplied via AaveModule. Test contract WMATIC balance:", WMATIC.balanceOf(address(this)) / 1 ether);

        uint256 finalATokenBalance = aaveModule.getSupplyBalance(address(WMATIC), address(this)); // Check module's aToken balance
        assertTrue(finalATokenBalance > initialATokenBalanceModule, "Module's aToken balance should increase after supply via module");
        console.log("Module's aWMATIC balance after module supply:", finalATokenBalance / 1 ether);

        // --- 4. Borrow USDC via AaveModule ---
        uint256 usdcBalanceBeforeModuleBorrow = USDC.balanceOf(address(this));
        console.log("USDC balance before module borrow:", usdcBalanceBeforeModuleBorrow / 1e6, "USDC");

        console.log("Attempting to borrow", (usdcToBorrowFromModule / 1e6).percentDiv(aaveModule.getLTV(address(WMATIC))), "USDC via AaveModule...");
        uint256 ltv = aaveModule.getLTV(address(WMATIC));
        //approve
        assertTrue(USDC.approve(address(AAVE_POOL), type(uint256).max), "USDC approve for AAVE_POOL failed");
        console.log("Borrowing USDC via AaveModule...");
        uint256 tenDollars = 20 * 1e6;
        DataTypes.ReserveData memory r = AaveLibrary.POOL.getReserveData(address(USDC));
        address variableDebtToken = r.variableDebtTokenAddress;
        ICreditDelegationToken(variableDebtToken).approveDelegation(address(aaveModule),type(uint256).max);
        console.log("Variable borrow index:", r.variableBorrowIndex);
        console.log("scaled amount:", tenDollars.rayDiv(r.variableBorrowIndex));
        console.log("total supply:", aaveModule.getSupplyBalance(address(WMATIC), address(this)));
        console.log("total debt:", aaveModule.getDebtBalance(address(WMATIC),address(this),InterestRateMode.VARIABLE));
        uint256 scaledBorrowedAmount = aaveModule.borrow(address(USDC), tenDollars, InterestRateMode.VARIABLE, address(this)); // Borrow on behalf of module for consistency if supply was for module
        assertTrue(scaledBorrowedAmount > 0, "Scaled borrowed amount via module should be greater than 0");

        console.log("BorrowedUSDC via AaveModule");
        //alanceOd debt token
        r = AaveLibrary.POOL.getReserveData(address(USDC));
        uint256 debtBalance = IERC20(r.variableDebtTokenAddress).balanceOf(address(this));
        
        console.log("total repay amount:", aaveModule.getRepayAmount(address(USDC), tenDollars, InterestRateMode.VARIABLE));
        console.log("total repay amount debt balance:", debtBalance);
        console.log("USDC balance of test contract:", USDC.balanceOf(address(this)));

        //repay
        uint256 halfBps = 5000;
        USDC.approve(address(AAVE_POOL), tenDollars.percentMul(halfBps));
        //transfer to module
        aaveModule.repay(address(USDC), tenDollars.percentMul(halfBps), InterestRateMode.VARIABLE, address(this));
        console.log("USDC balance of test contract after repay:", USDC.balanceOf(address(this)));
        console.log("total debt:", aaveModule.getDebtBalance(address(USDC),address(this),InterestRateMode.VARIABLE));
    }

    // Fallback to receive MATIC
    receive() external payable {}
}
