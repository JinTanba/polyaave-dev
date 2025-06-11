// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CTFExchangePriceOracle} from "@cti/ideas/CTFExchangePriceOracle.sol";
import {IOracle} from "../interfaces/Oralce.sol";

//Oracle for testing
contract PriceOracle is CTFExchangePriceOracle, IOracle {
    bool public fixedPriceEnabled;
    uint256 public fixedPrice;

    function setFixedPrice(uint256 _fixedPrice) external {
        fixedPriceEnabled = true;
        fixedPrice = _fixedPrice;
    }

    function disableFixedPrice() external {
        fixedPriceEnabled = false;
    }

    function getCurrentPrice(address positionToken) external view override returns (uint256) {
        if (fixedPriceEnabled) {
            return fixedPrice;
        }
        // Fall back to parent implementation
        return super.getCurrentPrice(positionToken);
    }
}
