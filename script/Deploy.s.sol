// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import  "../src/PolynanceLend.sol";
import "../src/adaptor/AaveModule.sol";
import "../src/predictionMarket/PredictionAsset.sol";
import "../src/predictionMarket/PolymarketPriceOracle.sol";

contract Deploy is Script {
    function run() public {
        vm.startBroadcast();
    }
}