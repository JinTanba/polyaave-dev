// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {BaseConditionalTokenIndex} from "@cti/BaseConditionalTokenIndex.sol";
import {IPositionToken} from "../interfaces/IPositionToken.sol";
import {IConditionalTokens} from "@cti/interfaces/IConditionalTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// interface IPositionToken {
//     function redeem() external returns(uint256); //send usdc to sender
// }
contract PredictionAsset is BaseConditionalTokenIndex,IPositionToken {
    address oracle;
    bytes32 questionId;

    constructor(address _oracle, bytes32 _questionId) {
        oracle = _oracle;
        questionId = _questionId;
    }

    function redeem() external returns(uint256) {
        bytes32 conditionId = conditionIds()[0];
        uint256[] memory indexset = indexSets();
        _withdraw(balanceOf(msg.sender));
        uint256 preBalance = IERC20(collateral()).balanceOf(address(this));
        IConditionalTokens(ctf()).redeemPositions(oracle,questionId,conditionId,indexset);
        IERC20(collateral()).transfer(msg.sender,IERC20(collateral()).balanceOf(address(this)) - preBalance);
        return IERC20(collateral()).balanceOf(address(this)) - preBalance;
    }

    function resolve()

}
