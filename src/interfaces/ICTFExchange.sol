// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;
// TODO: very unuseful, remove it this and `PolymarketOrderStruct`;
bytes32 constant ORDER_TYPEHASH = keccak256(
    "Order(uint256 salt,address maker,address signer,address taker,uint256 tokenId,uint256 makerAmount,uint256 takerAmount,uint256 expiration,uint256 nonce,uint256 feeRateBps,uint8 side,uint8 signatureType)"
);

struct Order {
    /// @notice Unique salt to ensure entropy
    uint256 salt;
    /// @notice Maker of the order, i.e the source of funds for the order
    address maker;
    /// @notice Signer of the order
    address signer;
    /// @notice Address of the order taker. The zero address is used to indicate a public order
    address taker;
    /// @notice Token Id of the CTF ERC1155 asset to be bought or sold
    /// If BUY, this is the tokenId of the asset to be bought, i.e the makerAssetId
    /// If SELL, this is the tokenId of the asset to be sold, i.e the takerAssetId
    uint256 tokenId;
    /// @notice Maker amount, i.e the maximum amount of tokens to be sold
    uint256 makerAmount;
    /// @notice Taker amount, i.e the minimum amount of tokens to be received
    uint256 takerAmount;
    /// @notice Timestamp after which the order is expired
    uint256 expiration;
    /// @notice Nonce used for onchain cancellations
    uint256 nonce;
    /// @notice Fee rate, in basis points, charged to the order maker, charged on proceeds
    uint256 feeRateBps;
    /// @notice The side of the order: BUY or SELL
    Side side;
    /// @notice Signature type used by the Order: EOA, POLY_PROXY or POLY_GNOSIS_SAFE
    SignatureType signatureType;
    /// @notice The order signature
    bytes signature;
}

enum SignatureType
// 0: ECDSA EIP712 signatures signed by EOAs
{
    EOA,
    // 1: EIP712 signatures signed by EOAs that own Polymarket Proxy wallets
    POLY_PROXY,
    // 2: EIP712 signatures signed by EOAs that own Polymarket Gnosis safes
    POLY_GNOSIS_SAFE
}

enum Side
// 0: buy
{
    BUY,
    // 1: sell
    SELL
}

enum MatchType
// 0: buy vs sell
{
    COMPLEMENTARY,
    // 1: both buys
    MINT,
    // 2: both sells
    MERGE
}

struct OrderStatus {
    bool isFilledOrCancelled;
    uint256 remaining;
}

interface ICTFExchange {
    event FeeCharged(address indexed receiver, uint256 tokenId, uint256 amount);
    event NewAdmin(address indexed newAdminAddress, address indexed admin);
    event NewOperator(address indexed newOperatorAddress, address indexed admin);
    event OrderCancelled(bytes32 indexed orderHash);
    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        uint256 makerAssetId,
        uint256 takerAssetId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled,
        uint256 fee
    );
    event OrdersMatched(
        bytes32 indexed takerOrderHash,
        address indexed takerOrderMaker,
        uint256 makerAssetId,
        uint256 takerAssetId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled
    );
    event ProxyFactoryUpdated(address indexed oldProxyFactory, address indexed newProxyFactory);
    event RemovedAdmin(address indexed removedAdmin, address indexed admin);
    event RemovedOperator(address indexed removedOperator, address indexed admin);
    event SafeFactoryUpdated(address indexed oldSafeFactory, address indexed newSafeFactory);
    event TokenRegistered(uint256 indexed token0, uint256 indexed token1, bytes32 indexed conditionId);
    event TradingPaused(address indexed pauser);
    event TradingUnpaused(address indexed pauser);

    function addAdmin(address admin_) external;
    function addOperator(address operator_) external;
    function admins(address) external view returns (uint256);
    function cancelOrder(Order memory order) external;
    function cancelOrders(Order[] memory orders) external;
    function domainSeparator() external view returns (bytes32);
    function fillOrder(Order memory order, uint256 fillAmount) external;
    function fillOrders(Order[] memory orders, uint256[] memory fillAmounts) external;
    function getCollateral() external view returns (address);
    function getComplement(uint256 token) external view returns (uint256);
    function getConditionId(uint256 token) external view returns (bytes32);
    function getCtf() external view returns (address);
    function getMaxFeeRate() external pure returns (uint256);
    function getOrderStatus(bytes32 orderHash) external view returns (OrderStatus memory);
    function getPolyProxyFactoryImplementation() external view returns (address);
    function getPolyProxyWalletAddress(address _addr) external view returns (address);
    function getProxyFactory() external view returns (address);
    function getSafeAddress(address _addr) external view returns (address);
    function getSafeFactory() external view returns (address);
    function getSafeFactoryImplementation() external view returns (address);
    function hashOrder(Order memory order) external view returns (bytes32);
    function incrementNonce() external;
    function isAdmin(address usr) external view returns (bool);
    function isOperator(address usr) external view returns (bool);
    function isValidNonce(address usr, uint256 nonce) external view returns (bool);
    function matchOrders(
        Order memory takerOrder,
        Order[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts
    ) external;
    function nonces(address) external view returns (uint256);
    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        external
        returns (bytes4);
    function onERC1155Received(address, address, uint256, uint256, bytes memory) external returns (bytes4);
    function operators(address) external view returns (uint256);
    function orderStatus(bytes32) external view returns (OrderStatus memory);
    function parentCollectionId() external view returns (bytes32);
    function pauseTrading() external;
    function paused() external view returns (bool);
    function proxyFactory() external view returns (address);
    function registerToken(uint256 token, uint256 complement, bytes32 conditionId) external;
    function registry(uint256) external view returns (uint256 complement, bytes32 conditionId);
    function removeAdmin(address admin) external;
    function removeOperator(address operator) external;
    function renounceAdminRole() external;
    function renounceOperatorRole() external;
    function safeFactory() external view returns (address);
    function setProxyFactory(address _newProxyFactory) external;
    function setSafeFactory(address _newSafeFactory) external;
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function unpauseTrading() external;
    function validateComplement(uint256 token, uint256 complement) external view;
    function validateOrder(Order memory order) external view;
    function validateOrderSignature(bytes32 orderHash, Order memory order) external view;
    function validateTokenId(uint256 tokenId) external view;
}