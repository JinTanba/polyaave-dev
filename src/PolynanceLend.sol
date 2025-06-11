// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces and Libraries
import "../src/interfaces/Oralce.sol";
import "../src/interfaces/IPositionToken.sol";
import "../src/interfaces/ILiquidityLayer.sol";

import "./libraries/Storage.sol";
import "./Core.sol";
import "./libraries/logic/BorrowLogic.sol";
import "./libraries/logic/MarketResolveLogic.sol";
import "./libraries/logic/SupplyLogic.sol";
import "./libraries/logic/LiquidationLogic.sol";
import "./libraries/PolynanceEE.sol";
import "./adaptor/AaveModule.sol";
import {IPoolAddressesProvider} from "aave-v3-core/contracts/interfaces/IPoolAddressesPROVIDER.sol";
import {ICreditDelegationToken} from "aave-v3-core/contracts/interfaces/ICreditDelegationToken.sol";
import {DataTypes} from "aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";
// OpenZeppelin contracts
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/protocol/libraries/math/PercentageMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract PolynanceLendingMarket is ERC721("Polynance Supply Position", "polySP") {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    // Constructor
    constructor(
        Storage.RiskParams memory riskParams
    ) {
        Storage.$ storage $ = Core.f();
        $.riskParams = riskParams;
        $.nextTokenId = 1; // Start token IDs from 1
        // Initialize the reserve for the supply asset
        address[] memory assets = new address[](1);
        assets[0] = riskParams.supplyAsset;
        address ll = address(new AaveModule(assets));
        $.riskParams.liquidityLayer = ll;
        console.log("=============  Liquidity Layer Address: ", ll);
        //approve to liquidityLayer
        IERC20(riskParams.supplyAsset).approve(ll, type(uint256).max);
        ICreditDelegationToken(AaveLibrary.POOL.getReserveData(riskParams.supplyAsset).variableDebtTokenAddress).approveDelegation(ll,type(uint256).max);
    }

    // ============ Supply Functions ============

    function supply(uint256 amount, address predictionAsset) external {
        Storage.$ storage $ = Core.f();
        uint256 tokenId = $.nextTokenId;
        _mint(msg.sender, tokenId);
        
        uint256 suppliedAmount = SupplyLogic.supply(
            _reserve(predictionAsset),
            _supplyPosition(tokenId),
            msg.sender,
            amount
        );
        $.nextTokenId += 1;
        emit PolynanceEE.Supply(msg.sender, suppliedAmount, suppliedAmount);
    }


    function deposit(uint256 collateralAmount, address predictionAsset) external {
        BorrowLogic.deposit(msg.sender, collateralAmount, predictionAsset,_position(msg.sender, predictionAsset), _reserve(predictionAsset));
        emit PolynanceEE.DepositCollateral(msg.sender, predictionAsset, collateralAmount);
    }

    function depositAndBorrow(uint256 collateralAmount, address predictionAsset) external returns (uint256) {
        console.log("======= Deposit and Borrow =======");
        uint256 borrowedAmount = BorrowLogic.depositAndBorrow(msg.sender, collateralAmount, predictionAsset,
            _position(msg.sender, predictionAsset), _reserve(predictionAsset));
        console.log("Borrowed Amount: ", borrowedAmount);
        emit PolynanceEE.DepositAndBorrow(msg.sender, predictionAsset, collateralAmount, borrowedAmount);
        return borrowedAmount;
    }

    function borrow(uint256 amount, address predictionAsset) external {
        uint256 borrowedAmount = BorrowLogic.borrow(_position(msg.sender, predictionAsset),_reserve(predictionAsset),predictionAsset, amount, msg.sender);
        emit PolynanceEE.Borrow(msg.sender, borrowedAmount, amount);
    }

    function repay(address predictionAsset) external returns (uint256) {
        uint256 repayAmount = BorrowLogic.repay(msg.sender, predictionAsset,
            _position(msg.sender, predictionAsset), _reserve(predictionAsset));
        emit PolynanceEE.Repay(msg.sender, repayAmount,repayAmount);
        return repayAmount;
    }

    // ============ Market Resolution Functions ============

    function resolve(address collateralAsset) external {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams memory rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(rp.supplyAsset, collateralAsset);
        
        MarketResolveLogic.resolve(
            MarketResolveLogic.ResolveInput({
                marketId: marketId,
                resolver: msg.sender
            })
        );
    }

    function claimBorrowerPosition(address collateralAsset) external {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams memory rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(rp.supplyAsset, collateralAsset);
        
        MarketResolveLogic.claimBorrowerPosition(marketId, msg.sender);
    }

    function claimLpPosition(address collateralAsset, uint256 tokenId) external returns (uint256) {
        require(ownerOf(tokenId) == msg.sender, "Not token owner");
        
        Storage.$ storage $ = Core.f();
        Storage.RiskParams memory rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(rp.supplyAsset, collateralAsset);
        
        uint256 payout = MarketResolveLogic.claimLpPosition(marketId, tokenId);
        
        // Burn the NFT after claim
        _burn(tokenId);
        
        return payout;
    }


    function getBorrowingCapacity(address user, address predictionAsset) external view returns (uint256) {
        return BorrowLogic.getBorrowingCapacity(user, predictionAsset,
            _position(user, predictionAsset), _reserve(predictionAsset));
    }

    function getMarketData() external view returns (
        uint256 totalSupplied,
        uint256 totalBorrowed,
        uint256 supplyRate,
        uint256 borrowRate,
        uint256 utilization
    ) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams memory rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(rp.supplyAsset, rp.collateralAsset);
        Storage.ReserveData storage reserve = Core.getReserveData(marketId);
        
        totalSupplied = reserve.totalScaledSupplied.rayMul(reserve.liquidityIndex);
        totalBorrowed = reserve.totalScaledBorrowed.rayMul(reserve.variableBorrowIndex);
        
        utilization = Core.calculateUtilization(totalBorrowed, totalSupplied);
        
        supplyRate = Core.calculateSupplyRate(
            Core.CalcSupplyRateInput({
                totalBorrowedPrincipal: totalBorrowed,
                totalPolynanceSupply: totalSupplied,
                riskParams: rp
            })
        );
        
        borrowRate = Core.calculateSpreadRate(
            Core.CalcPureSpreadRateInput({
                totalBorrowedPrincipal: totalBorrowed,
                totalPolynanceSupply: totalSupplied,
                riskParams: rp
            })
        );
        
        // Add Aave base rate
        ILiquidityLayer aave = ILiquidityLayer(rp.liquidityLayer);
        uint256 aaveRate = aave.getBorrowRate(rp.supplyAsset, rp.interestRateMode);
        borrowRate = borrowRate + aaveRate;
    }

    function _reserve(address predictionAsset) internal view returns (Storage.ReserveData storage) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams memory rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(rp.supplyAsset, predictionAsset);
        return $.markets[marketId];
    }

    function _position(address user, address predictionAsset) internal view returns (Storage.UserPosition storage) {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams memory rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(rp.supplyAsset, predictionAsset);
        return $.positions[keccak256(abi.encodePacked(marketId, user))];
    }

    function _supplyPosition(uint256 tokenId) internal view returns (Storage.SupplyPosition storage) {
        Storage.$ storage $ = Core.f();
        return $.supplyPositions[tokenId];
    }

    function getReserveData(address predictionAsset) external view returns (Storage.ReserveData memory r) {
        r = _reserve(predictionAsset); // Ensure reserve exists
    }

    function getSupplyPosition(uint256 tokenId) external view returns (Storage.SupplyPosition memory) {
        Storage.$ storage $ = Core.f();
        return $.supplyPositions[tokenId];
    }

    function getUserPosition(address user, address predictionAsset) external view returns (Storage.UserPosition memory) {
        Storage.$ storage $ = Core.f();
        bytes32 marketId = Core.getMarketId($.riskParams.supplyAsset, predictionAsset);
        return $.positions[Core.getPositionId(marketId, user)];
    }

    function getRiskParams() external view returns (Storage.RiskParams memory) {
        Storage.$ storage $ = Core.f();
        return $.riskParams;
    }

    function getResolutionData(address predictionAsset) external view returns (Storage.ResolutionData memory) {
        Storage.$ storage $ = Core.f();
        bytes32 marketId = Core.getMarketId($.riskParams.supplyAsset, predictionAsset);
        return $.resolutions[marketId];
    }
}