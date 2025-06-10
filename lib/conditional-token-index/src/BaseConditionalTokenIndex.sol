// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";


abstract contract BaseConditionalTokenIndex is ERC20, IERC1155Receiver, ERC165 {
    string internal _name;
    string internal _symbol;
    // @dev
    // Invariant conditions:
    // 1. If the set of positionids is the same, and the metadata and ctf addresses are the same, calculate the same indextoken.
    // 2. An indextoken is issued and can be withdrawn in a 1:1 ratio with the position token it contains.
    // 3. An indextoken cannot have two or more positions under the same conditionid.
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

    constructor() ERC20("",""){}

    function initialize(bytes calldata initData) external {
        require(msg.sender == $().factory,"PermissonError");
        ctf().setApprovalForAll(address(ctf()),true);
        //TODO
        _name = abi.decode($().specifications,(string));
        _symbol = abi.decode($().specifications,(string));
        _init(initData);
    }

    function deposit(uint256 amount) external {
        _deposit(amount);
    }

    function withdraw(uint256 amount) external {
        _withdraw(amount);
    }

    function _deposit(uint256 amount) internal virtual {
        uint256 len = components().length;
        uint256[] memory amts = new uint256[](len);
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                amts[i] = amount;
            }
        }
        _mint(msg.sender, amount);
        ctf().safeBatchTransferFrom(msg.sender, address(this), components(), amts, "");
    }

    function _withdraw(uint256 amount) internal virtual {
        uint256 len = components().length;

        uint256[] memory amts = new uint256[](len);
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                amts[i] = amount;
            }
        }
        _burn(msg.sender, amount);
        ctf().safeBatchTransferFrom(address(this), msg.sender, components(), amts, "");
    }

    function $() public view returns (StorageInCode memory args) {
        args = abi.decode(Clones.fetchCloneArgs(address(this)), (StorageInCode));
    }

    function immutableArgsRaw() external view returns (bytes memory) {
        return Clones.fetchCloneArgs(address(this));
    }

    /// @notice Component array getter
    function components() public view returns (uint256[] memory) {
        return $().components;
    }

    /// @notice Condition IDs getter
    function conditionIds() public view returns (bytes32[] memory) {
        return $().conditionIds;
    }

    /// @notice Index sets getter
    function indexSets() public view returns (uint256[] memory) {
        return $().indexSets;
    }

    function encodedSpecifications() public view returns (bytes memory) {
        return $().specifications;
    }

    function ctf() public view returns (IConditionalTokens) {
        return IConditionalTokens($().ctf);
    }

    function collateral() public view returns(address) {
        return $().collateral;
    }

    function priceOracle() public view returns(address) {
        return $().priceOracle;
    }

    function _init(bytes memory initData) internal virtual {}

    //TODO: make dynamic name
    function name() public override virtual view returns (string memory) {
        return _name;
    }

    //TODO: make dynamic symbol
    function symbol() public override virtual view returns (string memory) {
        return _symbol;
    }

    /// @dev EIP-1155 receiver hooks
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
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
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }


}

