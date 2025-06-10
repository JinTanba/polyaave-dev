// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseConditionalTokenIndex} from "./BaseConditionalTokenIndex.sol";
// @dev
// Invariant conditions:
// 1. If the set of positionids is the same, and the metadata and ctf addresses are the same, calculate the same indextoken.
// 2. An indextoken is issued and can be withdrawn in a 1:1 ratio with the position token it contains.
// 3. An indextoken cannot have two or more positions under the same conditionid.
contract ConditionalTokensIndex is BaseConditionalTokenIndex {
}
