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
        address[] memory assets = new address[](1);
        assets[0] = riskParams.supplyAsset;
        riskParams.liquidityLayer = address(new AaveModule(assets));
    }

    // ============ Supply Functions ============

    function supply(uint256 amount, address predictionAsset) external {
        Storage.$ storage $ = Core.f();
        uint256 tokenId = $.nextTokenId;
        _mint(msg.sender, tokenId);
        uint256 suppliedAmount = SupplyLogic.supply(msg.sender, amount, tokenId, predictionAsset);
        $.nextTokenId += 1;
        emit PolynanceEE.Supply(msg.sender, suppliedAmount, suppliedAmount);
    }

    // ============ Borrow Functions ============

    function borrow(uint256 amount, address predictionAsset) external {
        uint256 borrowedAmount = BorrowLogic.borrow(msg.sender, amount, predictionAsset);
        emit PolynanceEE.Borrow(msg.sender, borrowedAmount, amount);
    }

    function repay(uint256 amount, address predictionAsset) external {
        uint256 repayAmount = BorrowLogic.repay(msg.sender, amount, predictionAsset);
        emit PolynanceEE.Repay(msg.sender, repayAmount, amount);
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

    // ============ View Functions ============

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

    // ============ Admin Functions ============
    // Note: Access control will be added later

    function updateRiskParams(Storage.RiskParams memory newParams) external {
        Storage.$ storage $ = Core.f();
        $.riskParams = newParams;
    }

    function pauseMarket() external {
        Storage.$ storage $ = Core.f();
        $.riskParams.isActive = false;
    }

    function unpauseMarket() external {
        Storage.$ storage $ = Core.f();
        $.riskParams.isActive = true;
    }

    function collectProtocolRevenue(address to) external {
        Storage.$ storage $ = Core.f();
        Storage.RiskParams memory rp = $.riskParams;
        bytes32 marketId = Core.getMarketId(rp.supplyAsset, rp.collateralAsset);
        Storage.ReserveData storage reserve = Core.getReserveData(marketId);
        Storage.ResolutionData storage resolution = Core.getResolutionData(marketId);
        
        uint256 totalRevenue = reserve.accumulatedReserves;
        
        // Add protocol pool if market is resolved and not yet claimed
        if (resolution.isMarketResolved && !resolution.protocolClaimed && resolution.protocolPool > 0) {
            totalRevenue += resolution.protocolPool;
            resolution.protocolClaimed = true;
        }
        
        if (totalRevenue > 0) {
            reserve.accumulatedReserves = 0;
            IERC20(rp.supplyAsset).safeTransfer(to, totalRevenue);
            emit PolynanceEE.ReservesCollected(totalRevenue);
        }
    }
}