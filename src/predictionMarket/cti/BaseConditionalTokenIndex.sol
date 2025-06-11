// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IConditionalTokens} from "../../interfaces/IConditionalTokens.sol";


abstract contract BaseConditionalTokenIndex is ERC20, IERC1155Receiver, ERC165 {
    string internal _name;
    string internal _symbol;
    
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
       // uint256[] weights TODO: this is required.
    }

    // State variables
    bool public indexSolved;
    uint256 public totalCollateralRedeemed;
    uint256 public totalSupplyAtSolve; // Locked at solve time to ensure fair redemption calculations
    
    // Events
    event IndexSolved(uint256 totalCollateralRedeemed, uint256 totalSupply);
    event Redeemed(address indexed redeemer, uint256 indexAmount, uint256 collateralPayout);
    
    // Errors
    error NotAllConditionsResolved();
    error NoIndexTokensToRedeem();
    error RedemptionFailed();
    error IndexNotSolvedYet();
    error IndexAlreadySolved();
    error InsufficientCollateral();
    error CannotWithdrawAfterSolve();
    error CannotDepositAfterSolve();

    constructor() ERC20("",""){}

    function initialize(bytes calldata initData) external {
        require(msg.sender == $().factory,"PermissonError");
        ctf().setApprovalForAll(address(ctf()),true);
        (string memory name_, string memory symbol_) = abi.decode(initData, (string, string));
        _name = name_;
        _symbol = symbol_;
    }

    function deposit(uint256 amount) external {
        if (indexSolved) revert CannotDepositAfterSolve();
        _deposit(amount);
    }

    function withdraw(uint256 amount) external {
        if (indexSolved) revert CannotWithdrawAfterSolve();
        _withdraw(amount);
    }

    /**
     * @notice Solves the index by redeeming all underlying conditional tokens for collateral
     * @dev Can only be called once when all conditions are resolved
     */
    function solveIndex() public {
        if (indexSolved) revert IndexAlreadySolved();
        
        // Check if all conditions are resolved
        StorageInCode memory args = $();
        uint256 len = args.conditionIds.length;
        
        for (uint256 i = 0; i < len; i++) {
            if (ctf().payoutDenominator(args.conditionIds[i]) == 0) {
                revert NotAllConditionsResolved();
            }
        }
        
        totalSupplyAtSolve = totalSupply();
        if (totalSupplyAtSolve == 0) revert NoIndexTokensToRedeem();
        
        // Calculate total collateral before redemption
        uint256 collateralBefore = IERC20(args.collateral).balanceOf(address(this));
        
        // Redeem all positions held by the contract
        for (uint256 i = 0; i < len; i++) {
            uint256[] memory indexSetArray = new uint256[](1);
            indexSetArray[0] = args.indexSets[i];
            
            if (ctf().balanceOf(address(this), args.components[i]) == 0) continue;
            
            ctf().redeemPositions(
                args.collateral,
                bytes32(0), // TODO: Not versatile. Not good.
                args.conditionIds[i],
                indexSetArray
            );
        }

        uint256 collateralAfter = IERC20(args.collateral).balanceOf(address(this));
        totalCollateralRedeemed = collateralAfter - collateralBefore;
        
        if (totalCollateralRedeemed == 0) revert RedemptionFailed();
        
        indexSolved = true;
        
        emit IndexSolved(totalCollateralRedeemed, totalSupplyAtSolve);
    }

    function redeem() external {
        uint256 amount = balanceOf(msg.sender);
        if (amount == 0) revert NoIndexTokensToRedeem();
        if(!indexSolved) {
            if(canSolveIndex()) {
                solveIndex();
            } else {
                revert NotAllConditionsResolved();
            }
        }
        
        uint256 userShare = (totalCollateralRedeemed * amount) / totalSupplyAtSolve;
        
        if (IERC20($().collateral).balanceOf(address(this)) < userShare) {
            revert InsufficientCollateral();
        }
        
        _burn(msg.sender, amount);
        
        IERC20($().collateral).transfer(msg.sender, userShare);
        
        emit Redeemed(msg.sender, amount, userShare);
    }


    function simulateRedeem(uint256 amount) external view returns (uint256 expectedPayout, bool allResolved) {
        if (amount == 0) return (0, false);
        
        StorageInCode memory args = $();
        
        // If index is already solved, calculate from totalCollateralRedeemed
        if (indexSolved) {
            if (totalSupplyAtSolve > 0) {
                expectedPayout = (totalCollateralRedeemed * amount) / totalSupplyAtSolve;
            }
            return (expectedPayout, true);
        }
        
        // Otherwise, simulate the solve process
        uint256 len = args.conditionIds.length;
        allResolved = true;
        expectedPayout = 0;
        
        // Check if all conditions are resolved and calculate total payout
        for (uint256 i = 0; i < len; i++) {
            uint256 denominator = ctf().payoutDenominator(args.conditionIds[i]);
            
            if (denominator == 0) {
                allResolved = false;
                return (0, false);
            }
            
            // Get the balance of this position held by the index
            uint256 positionBalance = ctf().balanceOf(address(this), args.components[i]);
            
            if (positionBalance > 0) {
                // Calculate payout for this position
                uint256 payoutNumerator = 0;
                uint256 outcomeSlotCount = ctf().getOutcomeSlotCount(args.conditionIds[i]);
                
                // Sum up payout numerators for the index set
                for (uint256 j = 0; j < outcomeSlotCount; j++) {
                    if (args.indexSets[i] & (1 << j) != 0) {
                        payoutNumerator += ctf().payoutNumerators(args.conditionIds[i], j);
                    }
                }
                
                // Calculate payout for this position
                uint256 positionPayout = (positionBalance * payoutNumerator) / denominator;
                expectedPayout += positionPayout;
            }
        }
        
        // If there's a total payout, calculate user's share based on their proportion
        if (expectedPayout > 0 && totalSupply() > 0) {
            expectedPayout = (expectedPayout * amount) / totalSupply();
        }
        
        return (expectedPayout, allResolved);
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
        uint256[] memory componentsArray = components();
        ctf().safeBatchTransferFrom(msg.sender, address(this), componentsArray, amts, "");
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

    function name() public override virtual view returns (string memory) {
        return _name;
    }

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

    /**
     * @notice Gets the current collateral balance available for redemption
     * @return The amount of collateral available in the redemption pool
     */
    /**
     * @notice Checks if the index can be solved (all conditions resolved)
     * @return canSolve Whether all conditions are resolved and index hasn't been solved yet
     */
    function canSolveIndex() public view returns (bool canSolve) {
        if (indexSolved) return false;
        
        StorageInCode memory args = $();
        uint256 len = args.conditionIds.length;
        
        for (uint256 i = 0; i < len; i++) {
            if (ctf().payoutDenominator(args.conditionIds[i]) == 0) {
                return false;
            }
        }
        
        return true;
    }

    /**
     * @notice Gets the current collateral balance available for redemption
     * @return The amount of collateral available in the redemption pool
     */
    function getRedemptionPoolBalance() external view returns (uint256) {
        return IERC20($().collateral).balanceOf(address(this));
    }
    
    /**
     * @notice Calculates the collateral amount claimable for a given amount of index tokens
     * @param indexTokenAmount The amount of index tokens
     * @return collateralAmount The amount of collateral claimable
     */
    function getClaimableCollateral(uint256 indexTokenAmount) external view returns (uint256 collateralAmount) {
        if (!indexSolved || totalSupplyAtSolve == 0) return 0;
        return (totalCollateralRedeemed * indexTokenAmount) / totalSupplyAtSolve;
    }
    
    /**
     * @notice Gets the amount of collateral already claimed by users
     * @return The amount of collateral that has been claimed
     */
    function getClaimedCollateral() external view returns (uint256) {
        if (!indexSolved) return 0;
        uint256 remainingTokens = totalSupply();
        uint256 claimedTokens = totalSupplyAtSolve - remainingTokens;
        return (totalCollateralRedeemed * claimedTokens) / totalSupplyAtSolve;
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