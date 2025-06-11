// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

enum InterestRateMode {
    VARIABLE,
    FIXED
}

library Storage {
    /* "Polynance-Lending-V1-State" */
    bytes32 internal constant SLOT = 0x8e583c4f44da93fff6a80d84431a79217d3b6ed4fe4a3d9bf528a205decd0ea4;
    
    struct ReserveData {
        // Interest accumulation indices
        uint256 variableBorrowIndex;      // Tracks user debt accumulation
        uint256 liquidityIndex;   // Tracks LP earnings accumulation
        
        uint256 totalScaledBorrowed;             // Total borrowed by all users
        uint256 totalBorrowed; // CLAUDE: not scaled value
        uint256 totalScaledSupplied;             // Total supplied by all LPs
        uint256 totalCollateral;           // Total prediction tokens deposited
        
        // Cached values for gas efficiency
        uint256 lastUpdateTimestamp;       // Last index update
        uint256 cachedUtilization;         // Last calculated U
        
        // Profit tracking
        uint256 accumulatedSpread;         // Total spread earned
        uint256 accumulatedRedeemed;       // total redeemed()
        uint256 accumulatedReserves;       // Protocol reserves
    
    }

    struct ResolutionData {
        // Resolution status
        bool isMarketResolved;
        uint256 marketResolvedTimestamp;
        uint256 finalCollateralPrice;
        
        // Three pools (collateral redemption proceeds only)
        uint256 lpSpreadPool;      // LP's share of spread + excess
        uint256 borrowerPool;      // Borrower rebates
        uint256 protocolPool;      // Protocol revenue
        
        // Total values for reference
        uint256 totalCollateralRedeemed;
        uint256 aaveDebtRepaid;    // How much was repaid to Aave at resolution
        
        bool protocolClaimed;
    }

    
    struct UserPosition {
        uint256 collateralAmount;          // Prediction tokens deposited
        uint256 borrowAmount;              // Borrowed amount
        uint256 scaledDebtBalance;           //Debt scaled by borrowIndex(borrowAmount/variableBorrowIndex)
    }

    struct SupplyPosition {
        uint256 supplyAmount;              // Supplied amount
        uint256 scaledSupplyBalance;       // Supply scaled by polynance liquidityIndex
    }

    struct RiskParams {
        // Interest rate parameters
        InterestRateMode interestRateMode;
        uint256 baseSpreadRate;            // Minimum spread over Aave (Ray)
        uint256 optimalUtilization;        // Target U (Ray) e.g., 0.8e27
        uint256 slope1;                    // Rate slope when U < optimal (Ray)
        uint256 slope2;                    // Rate slope when U > optimal (Ray)
        uint256 reserveFactor;             // Protocol fee (basis points)

        
        // Risk parameters
        uint256 ltv;                       // Max loan-to-value (basis points)
        uint256 liquidationThreshold;      // Liquidation trigger (basis points)
        uint256 liquidationCloseFactor;    //Liquidation trigger (basis points)
        uint256 liquidationBonus;          // Liquidator incentive (basis points) e.g., 500 = 5%
        uint256 lpShareOfRedeemed;         // LP share of redeemed amount(basis points)
        
        // Market configuration
        uint256 maturityDate;              // Prediction market resolution
        address priceOracle;               // Oracle for collateral valuation
        address liquidityLayer;                // Aave integration contract
        
        // Fixed asset pair
        address supplyAsset;               // Asset LPs deposit (e.g., USDC)
        uint256 supplyAssetDecimals;
        uint256 collateralAssetDecimals;
        
        // Control
        address curator;                   // Market admin
        bool isActive;                     // Market accepting new positions
    }

    struct $ {
        // User positions: keccak256(marketsId, borrowAsset) => UserPosition
        mapping(bytes32 => UserPosition) positions;
        
        // Market state: keccak256(predictionAsset, borrowAsset) => ReserveData
        mapping(bytes32 => ReserveData) markets;
        // Supply positions: tokenId => SupplyPosition
        mapping(uint256 => SupplyPosition) supplyPositions;
        mapping(bytes32=>ResolutionData) resolutions;
        
        // Next token ID counter
        uint256 nextTokenId;
        
        // Risk parameters (single instance per contract)
        RiskParams riskParams;
    }

    function f() internal pure returns ($ storage l) {
        bytes32 slot = SLOT;
        assembly { l.slot := slot }
    }

}