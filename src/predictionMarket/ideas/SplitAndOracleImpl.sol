// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseConditionalTokenIndex} from "../cti/BaseConditionalTokenIndex.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../interfaces/ICTFExchange.sol";
import {CTFExchangePriceOracle} from "./CTFExchangePriceOracle.sol";
// @dev
// Invariant conditions:
// 1. If the set of positionids is the same, and the metadata and ctf addresses are the same, calculate the same indextoken.
// 2. An indextoken is issued and can be withdrawn in a 1:1 ratio with the position token it contains.
// 3. An indextoken cannot have two or more positions under the same conditionid.
contract SplitAndOracleImpl is BaseConditionalTokenIndex {
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    uint256[] public complements;
    uint256 private constant BPS = 10_000;
    uint256 immutable tradeRate=8_500;//85
    uint256 immutable TTL= 5 minutes;
    uint256 constant ONE = 10**18; 

    struct ProposeData {
        bytes32 orderHash;
        uint256 price;
        uint256 size;
        address proposer;
        uint256 tokenId;
    }
    mapping(bytes32 => ProposeData) internal priceProposed;

    // uint256 public weights;
    function _init(bytes memory initData) internal override {
        // weights = abi.decode(initData,(uint256));
        ERC20(collateral()).approve(address(ctf()), type(uint256).max);
        bytes32[] memory conditionIds = conditionIds();
        uint256[] memory _complements = new uint256[](conditionIds.length);
        for(uint256 i;i<conditionIds.length;i++) {
            uint256 idxs = indexSets()[i];
            uint256 idx = idxs==1?2:1;
            uint256 cmp = ctf().getPositionId(collateral(),ctf().getCollectionId(bytes32(0),conditionIds[i],idx));
            _complements[i] = cmp;
        }
        require(_complements.length==conditionIds.length,"InvalidComplement");
        complements = _complements;
    }

    function _deposit(uint256 inputUSDC) internal override {
       bytes32[] memory conditionIds = conditionIds();
       ERC20(collateral()).transferFrom(msg.sender, address(this), inputUSDC);
       uint256[] memory amounts = new uint256[](conditionIds.length);
       for(uint256 i;i<conditionIds.length;i++) amounts[i] = inputUSDC/conditionIds.length;
       for(uint256 i;i<conditionIds.length;i++) {
           uint256[] memory partition = new uint256[](2);
           partition[0] = 1;
           partition[1] = 2;
           ctf().splitPosition(collateral(),bytes32(0),conditionIds[i],partition,amounts[i]);
       }
       _mint(msg.sender,inputUSDC/conditionIds.length);
       emit Deposit(msg.sender,inputUSDC/conditionIds.length);
    }

    function _withdraw(uint256 amount) internal override {
        uint256 len = components().length;

        uint256[] memory amts = new uint256[](len);
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                amts[i] = amount;
            }
        }
        uint256 oldTotalSupply = totalSupply();
        _burn(msg.sender, amount);
        uint256 balance = ERC20(collateral()).balanceOf(address(this));
        ERC20(collateral()).transfer(msg.sender, balance*(amount/oldTotalSupply));
        ctf().safeBatchTransferFrom(address(this), msg.sender, components(), amts, "");
        emit Withdraw(msg.sender, amount);
    }

    //@notice
    //@param size 10^6
    function proposeOrder(Order calldata order, uint256 size) external returns(uint256) {
        bool find = false;
        for(uint256 i;i<complements.length;i++){
            if(complements[i]==order.tokenId) {
                find = true;
                break;
            }
        }
        if(!find) revert("InvalidTokenId");
        uint256 amount;
        CTFExchangePriceOracle.PriceData memory priceData = CTFExchangePriceOracle(priceOracle()).getCurrentPrice(order.tokenId);
        if(priceData.createdAt!=0&&priceData.createdAt+TTL>block.timestamp) {
            amount = priceData.price*size/ONE;//(priceE18 * size) / 1e18
            require(amount > ctf().balanceOf(address(this),order.tokenId),"TooBig");
            ERC20(collateral()).transferFrom(msg.sender, address(this), amount);
            ctf().safeTransferFrom(address(this), msg.sender, order.tokenId, amount, "");
        }else {
            //@dev price is 10^18
            uint256 price = CTFExchangePriceOracle(priceOracle()).proposePrice(order);
            amount = price*size/ONE > ctf().balanceOf(address(this),order.tokenId) ? ctf().balanceOf(address(this),order.tokenId) : price*size/ONE;
            ERC20(collateral()).transferFrom(msg.sender, address(this), amount);
            uint256 tradeAmount = amount*tradeRate/BPS;
            ctf().safeTransferFrom(address(this), msg.sender, order.tokenId, tradeAmount, "");
            bytes32 orderHash = CTFExchangePriceOracle(priceOracle()).getOrderHash(order);
            priceProposed[orderHash] = ProposeData({orderHash: orderHash, price: price, size: size, proposer: msg.sender, tokenId: order.tokenId});
        }
        return amount;
    }

    function resolveProposedOrder(bytes32 orderHash) external {
        //permissonless!!
        bool isFilled = CTFExchangePriceOracle(priceOracle()).getOrderStatus(orderHash);
        if(isFilled) {
            ProposeData memory pd = priceProposed[orderHash];
            uint256 price = CTFExchangePriceOracle(priceOracle()).getCurrentPrice(pd.tokenId).price;
            uint256 currentPrice = price > pd.price ? price : pd.price;
            uint256 amount = currentPrice*pd.size/ONE;
            uint256 refund = amount-(amount*tradeRate/BPS);
            ERC20(collateral()).transfer(pd.proposer,refund);
        }
        CTFExchangePriceOracle(priceOracle()).verifyProposedPrice(0);
    }

    function getComplement() external view returns(uint256[] memory) {
        return complements;
    }
    

}
