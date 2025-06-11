// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./Base.t.sol";
import "../src/libraries/Storage.sol";
import "../src/libraries/PolynanceEE.sol";
import "../src/interfaces/ILiquidityLayer.sol";
import "../src/interfaces/Oralce.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PolynanceLendingMarket} from "../src/PolynanceLend.sol";
import {AaveLibrary} from "../src/adaptor/AaveModule.sol";
import "../src/Core.sol";

import {IPositionToken} from "../src/interfaces/IPositionToken.sol";
struct IndexImage {
    address impl;
    bytes32[] conditionIds;
    uint256[] indexSets;
    bytes specifications;
    address priceOracle;
}



contract MarketResolveTest is PolynanceTest {

    address priceOracle = address(0x0987654321098765432109876543210987654321);
    address impl = address(0x1234567890123456789012345678901234567890);


    function create(uint256[] memory idx, bytes32[] memory cids) public {
        IndexImage memory indexImage1 = IndexImage({
            impl: impl,
            conditionIds: cids,
            indexSets: idx,
            specifications: "",
            priceOracle: priceOracle
        });
    }

}