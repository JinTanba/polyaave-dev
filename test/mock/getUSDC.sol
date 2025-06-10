// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/console.sol";
import "forge-std/Test.sol";

/**
 * @title IPool
 * @dev Minimal interface for Aave V3 Pool contract to supply and borrow.
 */
interface IPool {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;
}

/**
 * @title IWETH
 * @dev Minimal interface for WETH/WMATIC token, including deposit and ERC20 functions.
 */
interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title IERC20
 * @dev Minimal interface for ERC20 token functions.
 */
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title AaveDirectInteractor
 * @author Gemini
 * @notice A contract to supply WETH and borrow USDC directly from Aave V3 on Polygon.
 * This contract is designed for a fork environment and does not use any abstractions.
 */
contract AaveDirectInteractor {
    // --- Aave V3 Polygon Mainnet Addresses ---
    IPool private constant AAVE_POOL = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IWETH private constant WMATIC = IWETH(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);
    IERC20 private constant USDC = IERC20(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359); // 6 decimals

    // --- Events ---
    event AssetsBorrowed(
        address collateralAsset,
        uint256 collateralAmount,
        address borrowedAsset,
        uint256 borrowedAmount
    );

    /**
     * @notice Supplies WMATIC as collateral and borrows USDC against it from the Aave V3 Pool.
     * @dev This function must be called with enough MATIC sent as `msg.value` to cover the supply amount.
     * 1. Wraps the incoming MATIC (`msg.value`) into WMATIC.
     * 2. Approves the Aave Pool to spend the WMATIC.
     * 3. Supplies the WMATIC to the Aave Pool, using this contract as the owner of the position.
     * 4. Borrows the specified amount of USDC, which is sent to this contract.
     * @param usdcAmountToBorrow The amount of USDC to borrow (e.g., 150 * 1e6 for 150 USDC).
     */
    function supplyWethAndBorrowUsdc(uint256 usdcAmountToBorrow) external payable {
        uint256 wmaticToSupply = msg.value;

        // --- Input Validation ---
        require(wmaticToSupply > 0, "AaveDirectInteractor: Must supply more than 0 MATIC.");
        require(usdcAmountToBorrow > 0, "AaveDirectInteractor: Must borrow more than 0 USDC.");

        console.log("Received", wmaticToSupply / 1e18, "MATIC to supply.");

        // --- 1. Wrap MATIC to get WMATIC ---
        WMATIC.deposit{value: wmaticToSupply}();
        uint256 wmaticBalance = WMATIC.balanceOf(address(this));
        require(wmaticBalance >= wmaticToSupply, "AaveDirectInteractor: WMATIC wrapping failed.");
        console.log("Wrapped to", wmaticBalance / 1e18, "WMATIC.");

        // --- 2. Approve Aave V3 Pool to spend our WMATIC ---
        bool approved = WMATIC.approve(address(AAVE_POOL), wmaticToSupply);
        require(approved, "AaveDirectInteractor: Aave Pool WMATIC approval failed.");
        console.log("Approved Aave V3 Pool to spend WMATIC.");

        // --- 3. Supply WMATIC to Aave V3 Pool ---
        // We supply on behalf of this contract (address(this)).
        AAVE_POOL.supply(address(WMATIC), wmaticToSupply, address(this), 0);
        console.log("Supplied", wmaticToSupply / 1e18, "WMATIC to Aave.");

        // --- 4. Borrow USDC from Aave V3 Pool ---
        uint256 usdcBalanceBefore = USDC.balanceOf(address(this));
        console.log("USDC balance before borrow:", usdcBalanceBefore / 1e6);

        // Borrow with variable interest rate (Mode 2) on behalf of this contract.
        AAVE_POOL.borrow(address(USDC), usdcAmountToBorrow, 2, 0, address(this));

        uint256 usdcBalanceAfter = USDC.balanceOf(address(this));
        console.log("USDC balance after borrow:", usdcBalanceAfter / 1e6);
        require(
            usdcBalanceAfter > usdcBalanceBefore,
            "AaveDirectInteractor: Borrowing USDC appears to have failed."
        );

        emit AssetsBorrowed(
            address(WMATIC),
            wmaticToSupply,
            address(USDC),
            usdcAmountToBorrow
        );

        console.log("Successfully supplied WMATIC and borrowed USDC.");
    }

    /**
     * @dev Fallback function to allow the contract to receive MATIC.
     */
    receive() external payable {}
}
