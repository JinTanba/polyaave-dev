// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CTFExchangePriceOracle} from "./ideas/CTFExchangePriceOracle.sol";
import {IOracle} from "../interfaces/Oralce.sol";
import {BaseConditionalTokenIndex} from "./cti/BaseConditionalTokenIndex.sol";

//Oracle for testing
contract PriceOracle is CTFExchangePriceOracle, IOracle {
    bool public fixedPriceEnabled;
    uint256 public fixedPrice;

    constructor(
        address _ctfExchange,
        uint256 _ttl,
        uint256 _minUsdcNotional
    ) CTFExchangePriceOracle(_ctfExchange, _ttl, _minUsdcNotional) {}

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
        uint256[] memory tokenIds = BaseConditionalTokenIndex(positionToken).components();
        uint256 price = 0;
        for(uint256 i = 0; i < tokenIds.length; i++) {
            PriceData memory priceData = priceFeed[tokenIds[i]];
            price += priceData.price;
        }

        return price;
    }
}
