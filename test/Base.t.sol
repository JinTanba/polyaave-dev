// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/console.sol";

// --- INTERFACES ---

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
}

interface IWETH is IERC20 {
    function deposit(uint256 amount) external payable;
}


contract PolynanceTest is Test {
    // --- FORK CONFIGURATION ---
    string internal constant POLYGON_RPC_URL = "https://polygon-mainnet.g.alchemy.com/v2/cidppsnxqV4JafKXVW7qd9N2x6wTvTpN";
    uint256 internal constant FORK_BLOCK_NUMBER = 72384249; // A recent, stable block

    // --- POLYGON MAINNET ADDRESSES ---
    IPool   internal constant AAVE_POOL = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IWETH   internal constant WMATIC    = IWETH(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);
    IERC20  internal constant USDC      = IERC20(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359); // 6 decimals
    address internal rich;

    function setUp() public virtual {
        vm.createSelectFork(POLYGON_RPC_URL, FORK_BLOCK_NUMBER);
        rich = msg.sender;

        _procureUsdcForAccount(
            msg.sender, 
            10000 ether, // 100 MATIC to supply
            500 * 10 ** 6 // 500 USDC to borrow
        );
    }

    /**
     * @notice Procures USDC for a specific account by having them supply MATIC to Aave.
     * @dev This function uses `vm.prank` to make the `actor` perform all operations.
     * @param actor The address that will supply collateral and receive the borrowed USDC.
     * @param maticToSupply The amount of MATIC to `deal` to the actor and supply to Aave.
     * @param usdcToBorrow The amount of USDC the actor will borrow.
     */
    function _procureUsdcForAccount(address actor, uint256 maticToSupply, uint256 usdcToBorrow) internal {
        console.log("--- Procuring USDC for account:", actor, "---");

        // 1. Fund the actor with the MATIC needed for the operation.
        vm.deal(actor, maticToSupply);
        require(actor.balance >= maticToSupply, "Failed to deal MATIC to actor");

        // 2. Impersonate the actor to perform the Aave operations.
        actor = address(this);

        // This entire block is now executed by `actor`
        // `msg.sender` is `actor`, and `msg.value` is paid from `actor`.
        {
            console.log(actor);
            // Wrap MATIC into WMATIC
            WMATIC.deposit{value: maticToSupply}(maticToSupply);
            console.log("Actor wrapped MATIC.",WMATIC.balanceOf(actor));
            require(WMATIC.balanceOf(actor) >= maticToSupply, "Failed to wrap MATIC");

            // Approve Aave Pool to spend WMATIC
            WMATIC.approve(address(AAVE_POOL), maticToSupply);
            console.log("Actor approved Aave Pool.");

            // Supply WMATIC to Aave on behalf of self
            AAVE_POOL.supply(address(WMATIC), maticToSupply, actor, 0);
            console.log("Actor supplied WMATIC.");

            // Borrow USDC from Aave to self
            AAVE_POOL.borrow(address(USDC), usdcToBorrow, 2, 0, actor); // Mode 2: Variable
            console.log("Actor borrowed USDC.");
        }

        // 3. Verification
        uint256 finalUsdcBalance = USDC.balanceOf(actor);
        assertEq(finalUsdcBalance, usdcToBorrow, "Actor's final USDC balance is incorrect.");
        console.log("Successfully procured %e USDC for actor.", usdcToBorrow);
        console.log("-----------------------------------------");
    }
}