// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {BaseConditionalTokenIndex} from "./BaseConditionalTokenIndex.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

contract ConditionalTokensIndexFactory is IERC1155Receiver {
    IConditionalTokens public immutable ctf;
    address public immutable collateral;

    struct IndexImage {
        address impl;
        bytes32[] conditionIds;
        uint256[] indexSets;
        bytes specifications;
        address priceOracle;
    }

    struct StorageInCode{
        uint256[] components;
        bytes32[] conditionIds;
        uint256[] indexSets;
        bytes specifications;
        address factory;
        address ctf;
        address collateral;
        address impl;
        address priceOracle;
    }

    event IndexCreated(address indexed index, uint256[] components, bytes specifications);
    event IndexMerged(address indexed newIndex, address[] mergedIndex, uint256 amount, address executer);
    
    error NotExistIndex();
    error LengthMismatch();
    error InvalidIndexSet();
    error InvalidCondition();
    error DuplicateCondition();
    error FailIndexInit(string);
    error FailIndexMerge(string);
    error FailIndexSplit(string);


    constructor(address ctf_, address collateral_) {
        ctf = IConditionalTokens(ctf_);
        collateral = collateral_;
    }

    function createIndex(IndexImage calldata indexImage, bytes calldata initData) external returns(address) {
        return _createIndex(indexImage,initData);
    }

    function createIndexWithFunding(IndexImage calldata indexImage, bytes calldata initData, uint256 funding) external returns(address) {
        address instance = _createIndex(indexImage,initData);
        BaseConditionalTokenIndex indexInstance = BaseConditionalTokenIndex(instance);
        uint256[] memory components = $(instance).components;
        uint256[] memory fundingBatch = new uint256[](components.length);
        for(uint256 i;i<components.length;i++) fundingBatch[i] = funding;
        IConditionalTokens(ctf).safeBatchTransferFrom(msg.sender, address(this), components, fundingBatch, bytes(""));
        IConditionalTokens(ctf).setApprovalForAll(instance, true);
        indexInstance.deposit(funding);
        if(indexInstance.balanceOf(address(this)) != funding) revert FailIndexInit("balance");
        indexInstance.transfer(msg.sender,funding);
        return instance;
    }
 
    function mergeIndex(
        address impl,
        bytes calldata specifications,
        bytes calldata initData,
        address[] memory indexList, 
        uint256 mergeAmount,
        address priceOracle
    ) external returns(address newInstance) {
        //1. check existence of all indexList
        uint256 p = 0;
        IndexImage[] memory images = new IndexImage[](indexList.length);
        for (uint256 i;i<indexList.length;i++) {
            BaseConditionalTokenIndex(indexList[i]).transferFrom(msg.sender,address(this),mergeAmount);
            BaseConditionalTokenIndex(indexList[i]).withdraw(mergeAmount);
            IndexImage memory image = _recoveryIndexImage(indexList[i]);
            p += image.indexSets.length;
            images[i]=image;
        }
        //2. create new index
        uint256[] memory newIndexSets = new uint256[](p);
        bytes32[] memory newConditionIds = new bytes32[](p);
        uint256 x=0;
        for(uint256 j;j<images.length;j++) {
             IndexImage memory image = images[j];
             for(uint256 i;i<image.indexSets.length;i++) {
                newIndexSets[x] = image.indexSets[i];
                newConditionIds[x] = image.conditionIds[i];
                x++;
             }
        }
        newInstance = _createIndex(IndexImage(impl,newConditionIds,newIndexSets,specifications,priceOracle), initData);
        IConditionalTokens(ctf).setApprovalForAll(newInstance, true);
        BaseConditionalTokenIndex(newInstance).deposit(mergeAmount);
        BaseConditionalTokenIndex(newInstance).transfer(msg.sender, mergeAmount);
    }


    function _recoveryIndexImage(address instance) internal view returns(IndexImage memory image) {
        StorageInCode memory codeInStorage = $(instance);
        bytes memory encoded = abi.encode(codeInStorage);
        if(instance != Clones.predictDeterministicAddressWithImmutableArgs(
            codeInStorage.impl, encoded, keccak256(encoded), address(this))
        ) revert NotExistIndex();
        image = IndexImage(codeInStorage.impl, codeInStorage.conditionIds,codeInStorage.indexSets, codeInStorage.specifications,codeInStorage.priceOracle);
    }

    function _createIndex(IndexImage memory indexImage, bytes calldata initData) internal returns (address index) {
        (uint256[] memory components, bytes memory immutableArgs) = composeIndex(indexImage);
        bytes32 salt = keccak256(immutableArgs);
        index = Clones.predictDeterministicAddressWithImmutableArgs(indexImage.impl, immutableArgs, salt);
        if(index.code.length!=0) return index;
        index = Clones.cloneDeterministicWithImmutableArgs(indexImage.impl, immutableArgs, salt);
        BaseConditionalTokenIndex(index).initialize(initData);
        emit IndexCreated(index, components, indexImage.specifications);
    }

    function computeIndex(IndexImage memory indexImage) public view returns (address predicted) {
        (,bytes memory immutableArgs) = composeIndex(indexImage);
        predicted = Clones.predictDeterministicAddressWithImmutableArgs(indexImage.impl, immutableArgs, keccak256(immutableArgs), address(this));
    }

    function composeIndex(IndexImage memory indexImage) internal view returns (uint256[] memory components, bytes memory immutableArgs) {
        bytes32[] memory conditionIds = indexImage.conditionIds;
        uint256[] memory indexSets = indexImage.indexSets;
        uint256 n = conditionIds.length;

        if (n != indexSets.length) revert LengthMismatch();

        components = new uint256[](n);

        for (uint256 i = 0; i < n; ++i) {
            //One condition One Collection
            uint256 slots = ctf.getOutcomeSlotCount(conditionIds[i]);
            if (slots == 0) revert InvalidCondition();
            if (indexSets[i] == 0 || indexSets[i] >= (1 << slots)) revert InvalidIndexSet();
            for (uint256 j = 0; j < i; ++j) {
                if (conditionIds[j] == conditionIds[i]) revert DuplicateCondition();
            }
            components[i] = ctf.getPositionId(
                collateral, ctf.getCollectionId(bytes32(0), conditionIds[i], indexSets[i])
            );
        }

        //TODO:do math
        for (uint256 i = 0; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (components[j] < components[i]) {
                    (components[i], components[j]) = (components[j], components[i]);
                }
            }
        }

        immutableArgs = abi.encode(
            StorageInCode(
                components,
                indexImage.conditionIds,
                indexImage.indexSets,
                indexImage.specifications,
                address(this),
                address(ctf),
                collateral,
                indexImage.impl,
                indexImage.priceOracle
            )
        );
        
    }

    function $(address instance) public view returns (StorageInCode memory args) {
        args = abi.decode(Clones.fetchCloneArgs(instance), (StorageInCode));
    }


    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        pure
        override
        returns (bool)
    {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }


}
