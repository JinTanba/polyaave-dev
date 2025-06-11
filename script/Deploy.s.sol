// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PolynanceLendingMarket} from "../src/PolynanceLend.sol";
import {Storage, InterestRateMode} from "../src/libraries/Storage.sol";
import {PriceOracle} from "../src/predictionMarket/PolymarketPriceOracle.sol";
import {AaveModule} from "../src/adaptor/AaveModule.sol";

contract Deploy is Script {
    function run() external returns (PolynanceLendingMarket market) {
        // Fetch the private key from env (set via `export PRIVATE_KEY=...`)
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // ------------------ Configure Risk Params ------------------
        Storage.RiskParams memory rp;

        // Interest rate / spread configuration (example values – adjust as needed)
        rp.interestRateMode = InterestRateMode.VARIABLE;
        rp.baseSpreadRate      = 0.02e27;   // 2% in Ray
        rp.optimalUtilization  = 0.8e27;    // 80% U
        rp.slope1              = 0.04e27;   // 4% slope below optimal
        rp.slope2              = 0.75e27;   // 75% slope above optimal
        rp.reserveFactor       = 1000;      // 10% protocol fee (bps)

        // Risk limits (bps – example values)
        rp.ltv                     = 8000;  // 80% LTV
        rp.liquidationThreshold    = 8500;  // 85% liquidation threshold
        rp.liquidationCloseFactor  = 9000;  // 90% close factor
        rp.liquidationBonus        = 500;   // 5% bonus
        rp.lpShareOfRedeemed       = 1000;  // 10% LP share

        // Market meta
        rp.limitDate            = block.timestamp + 10 days;
        address ctfe = 0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E;
        uint256 ttl = 1 days;
        uint256 minuds = 5e6; // 0.05 USDC
        rp.priceOracle             = address(new PriceOracle(
            ctfe, // <-- set your Chainlink TFE address
            ttl, // <-- set your TTL (time to live)
            minuds // <-- set your minimum USD value for price updates
        )); // <-- set your oracle address

        address[] memory assets = new address[](1);
        assets[0] = address(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359); // Polygon USDC
        rp.liquidityLayer          = address(new AaveModule(assets)); // filled in constructor of PolynanceLendingMarket

        // Asset configuration (Polygon USDC as supply asset)
        rp.supplyAsset             = address(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359);
        rp.supplyAssetDecimals     = 6;
        rp.collateralAssetDecimals = 18;

        // Admin / status
        rp.curator                 = msg.sender;
        rp.isActive                = true;

        // ------------------ Deploy Contract ------------------
        market = new PolynanceLendingMarket(rp);
        //for test
        PriceOracle(rp.priceOracle).setFixedPrice(0.8 * 10 ** 18);


        vm.stopBroadcast();
    }
}

 