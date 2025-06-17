// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./DataStruct.sol";

library StorageV2 {
    /* "Polynance-Lending-V2-PureDriven" */
    bytes32 internal constant SLOT = keccak256("Polynance-Lending-V1");
    bytes32 internal constant ZERO_ID = bytes32(0);
    
    
    /**
     * @notice PureDriven storage using encoded bytes
     * @dev Single mapping for all data types
     */
    struct $ {
        mapping(bytes32 => bytes) data;
    }
    
    /**
     * @notice Get storage pointer
     * @dev Diamond storage pattern
     */
    function f() internal pure returns ($ storage l) {
        bytes32 slot = SLOT;
        assembly { l.slot := slot }
    }

    // ========== Generic Load/Commit Functions ==========

    /**
     * @notice Load encoded data from storage
     * @param key Storage key
     * @return Encoded data
     */
    function _load(bytes32 key) internal view returns (bytes memory) {
        return f().data[key];
    }

    /**
     * @notice Commit encoded data
     * @param key Storage key
     * @param encodedData Data to store (already encoded)
     */
    function _commit(bytes32 key, bytes memory encodedData) internal {
        f().data[key] = encodedData;
    }

    function next(DataType dataType,bytes memory data, bytes32 id) internal {
        bytes32 storageKey = keccak256(abi.encode(dataType, id));
        _commit(storageKey,data);
    }
    
    // ========== Typed Commit Functions ==========
    function getPool() internal view returns (PoolData memory) {
        bytes32 key = keccak256(abi.encode(DataType.POOL_DATA,ZERO_ID));
        bytes memory data = _load(key);
        return abi.decode(data, (PoolData));
    }

    function getRiskParams() internal view returns (RiskParams memory) {
        bytes32 key = keccak256(abi.encode(DataType.RISK_PARAMS,ZERO_ID));
        bytes memory data = _load(key);
        return abi.decode(data, (RiskParams));
    }

    function getMarketData(bytes32 id) internal view returns (MarketData memory) {
        bytes32 key = keccak256(abi.encode(DataType.MARKET_DATA, id));
        bytes memory data = _load(key);
        return abi.decode(data, (MarketData));
    }

    function getUserPosition(bytes32 id) internal view returns (UserPosition memory) {
        bytes32 key = keccak256(abi.encode(DataType.USER_POSITION, id));
        bytes memory data = _load(key);
        return abi.decode(data, (UserPosition));
    }
    function getResolutionData(bytes32 id) internal view returns (ResolutionData memory) {
        bytes32 key = keccak256(abi.encode(DataType.RESOLUTION_DATA, id));
        bytes memory data = _load(key);
        return abi.decode(data, (ResolutionData));
    }

    function reserveId(
        address asset,
        address predictionAsset
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(asset, predictionAsset));
    }

    function userPositionId(
        bytes32 reserveId_,
        address user
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(reserveId_, user));
    }
    
}

