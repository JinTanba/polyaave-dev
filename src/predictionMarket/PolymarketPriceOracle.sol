// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CTFExchangePriceOracle} from "@cti/ideas/CTFExchangePriceOracle.sol";
import {IOracle} from "../interfaces/Oralce.sol";

contract PriceOracle is CTFExchangePriceOracle, IOracle {
}
