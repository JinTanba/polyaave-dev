// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPositionToken {
    function redeem() external returns(uint256); //send usdc to sender
}