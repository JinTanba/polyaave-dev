// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracle {
    function getCurrentPrice(address positionToken) view external returns(uint256);
}