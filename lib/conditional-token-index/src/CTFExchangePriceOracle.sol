// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {ICTFExchange} from "./interfaces/ICTFExchange.sol";
import { Side, Order, OrderStatus } from "./libs/PolymarketOrderStruct.sol";

contract CTFExchangePriceOracle {

    event PriceFeed(
        uint256 indexed tokenId,
        uint256 price,
        uint256 timestamp,
        address indexed keeper
    );

    event PriceProposed(
        bytes32 orderHash,
        uint256 price,
        uint256 timestamp,
        address indexed keeper
    );

    error AlreadyUsed();
    error ZeroDivide();
    error InvalidComplement();
    error TooSmall();


    struct PriceData {
        uint256 price;
        uint256 createdAt;
    }

    struct PendingPriceData {
        uint256 price;
        uint256 createdAt;
        bytes32 orderHash;
        uint256 tokenId;
        uint256 complement;
        uint256 complementPrice;
    }

    ICTFExchange public immutable ctfExchange;
    uint256 internal immutable TTL;//1 min
    /// price = (μUSDC / CTF) * 10^(PRICE_DECIMALS)
    uint256 internal constant PRICE_DECIMALS = 18;
    uint256 internal constant ONE = 10 ** PRICE_DECIMALS;
    uint256 internal immutable MIN_USDC_NOTIONAL;

    mapping(uint tokenId => PriceData price) internal priceFeed;
    PendingPriceData[] public pendingPriceData;

    
    constructor(address _ctfExchange, uint256 _ttl, uint256 _minUsdcNotional) {
        ctfExchange = ICTFExchange(_ctfExchange);
        TTL = _ttl;
        MIN_USDC_NOTIONAL = _minUsdcNotional;
    }

    //Phase1: Declare order before post
    function proposePrice(Order calldata order) external returns(uint256) {
        bytes32 orderHash = ctfExchange.hashOrder(order);

        //check order is not filled or cancelled, send before order is filled
        OrderStatus memory orderStatus = ctfExchange.orderStatus(orderHash);
        if(orderStatus.isFilledOrCancelled||orderStatus.remaining>0) revert AlreadyUsed();

        (uint256 price, uint256 complementPrice) = _calcPrice(order);
        uint256 complement = ctfExchange.getComplement(order.tokenId);
        
        pendingPriceData.push(PendingPriceData({
            createdAt: block.timestamp,
            orderHash: orderHash,
            tokenId: order.tokenId,
            price: price,
            complement: complement,
            complementPrice: complementPrice
        }));
        emit PriceProposed(orderHash, price, block.timestamp, msg.sender);
        return price;
    }

    function verifyProposedPrice(uint256 max) external {
        uint256 end = (max>=pendingPriceData.length || max==0)? pendingPriceData.length : max;
        PendingPriceData[] memory keep = new PendingPriceData[](pendingPriceData.length);

        uint256 k = 0;
        for (uint256 i = 0; i < end; i++) {
            PendingPriceData memory pd = pendingPriceData[i];
            (bool isValid, bool isKeep) = _validate(pd);
            if(isValid) {
                // filled and not expired
                _updatePrice(pd.tokenId, pd.price, pd.createdAt);
                _updatePrice(pd.complement, pd.complementPrice, pd.createdAt);
            } else if(isKeep) {
                // not filled but not expired
                keep[k++]=pd;
            }
        }

        for (uint256 j = end; j < pendingPriceData.length; ++j) keep[k++]=pendingPriceData[j]; //copy rest

        assembly { mstore(keep, k) } //shrink array
        pendingPriceData = keep; //replace
    }

    function _validate(PendingPriceData memory pending) internal view returns(bool isValid,bool isKeep) {
        OrderStatus memory orderStatus = ctfExchange.orderStatus(pending.orderHash);
        bool isFilled = orderStatus.isFilledOrCancelled && orderStatus.remaining==0;
        bool isExpired = block.timestamp - pending.createdAt > TTL;
        isValid = isFilled && !isExpired;
        isKeep = !isExpired;
    }

    function _updatePrice(uint256 tokenId, uint256 price, uint256 createdAt) internal {
        PriceData memory currentPriceData = priceFeed[tokenId];
        if(currentPriceData.createdAt==0||currentPriceData.createdAt < createdAt) {
            priceFeed[tokenId] = PriceData({price: price, createdAt: createdAt});
            emit PriceFeed(tokenId, price, block.timestamp, msg.sender);
        }
    }
    
    function _calcPrice(Order memory o) public view returns (uint256, uint256) {
        uint256 collateralAmount  = (o.side == Side.BUY) ? o.makerAmount : o.takerAmount;
        if(collateralAmount < MIN_USDC_NOTIONAL) revert TooSmall();
        uint256 ctfTokenAmount = (o.side == Side.BUY) ? o.takerAmount : o.makerAmount;
        if(ctfTokenAmount == 0) revert ZeroDivide();
        uint256 basePrice = (collateralAmount * ONE) / ctfTokenAmount;
        if(basePrice <= ONE) {
            return (basePrice, ONE-basePrice);
        }
        return (basePrice, 0);
    }

    function getPrice(uint256 tokenId) public view returns (PriceData memory) {
        return priceFeed[tokenId];
    }

    function getOrderHash(Order calldata order) external view returns (bytes32) {
        return ctfExchange.hashOrder(order);
    }

    function getOrderStatus(bytes32 orderHash) external view returns (bool isFilled) {
        OrderStatus memory orderStatus = ctfExchange.orderStatus(orderHash);
        isFilled = orderStatus.isFilledOrCancelled && orderStatus.remaining==0;
    }

    function getTTL() external view returns (uint256) {
        return TTL;
    }

    function getPendingPriceData() external view returns (PendingPriceData[] memory) {
        return pendingPriceData;
    }

    function scanPendingPriceData() external view returns(bool) {
        for(uint256 i = 0; i < pendingPriceData.length; i++) {
            PendingPriceData memory pd = pendingPriceData[i];
            (bool isValid,) = _validate(pd);
            if(isValid) {
                return true;
            }
        }
        return false;
    }


}