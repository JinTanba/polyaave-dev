# MarketResolveLogic Implementation Strategy

## Overview

The MarketResolveLogic is the critical component that handles the transition from active prediction markets to settled states, enabling users to redeem their positions based on market outcomes.

## Current System Analysis

### Architecture Phases
1. **Active Phase**: 
   - LPs supply assets (e.g., USDC) and earn yield
   - Borrowers deposit prediction tokens as collateral
   - Borrowers receive leveraged exposure to prediction outcomes

2. **Resolution Phase** (Missing Implementation):
   - Prediction market reaches maturity date
   - Oracle determines final prediction token values
   - System calculates final settlement values

3. **Settlement Phase** (Missing Implementation):
   - Users redeem positions based on market outcome
   - LPs withdraw principal + interest + spread earnings
   - Borrowers get collateral back (if any remaining after debt settlement)

## Proposed MarketResolveLogic Implementation

### Core Data Structures

```solidity
struct MarketResolutionInput {
    uint256 finalPredictionTokenPrice;  // Final price from oracle (Ray)
    uint256 resolutionTimestamp;        // When market was resolved
    bool isWinningOutcome;              // True if prediction was correct
}

struct SettlementCalculation {
    uint256 totalCollateralValue;      // Total value of all collateral at resolution
    uint256 totalDebtToSettle;         // Total debt including interest
    uint256 protocolSurplus;           // Excess funds for LPs
    uint256 protocolDeficit;           // Shortfall to handle
}

struct UserRedemptionData {
    uint256 collateralValue;           // User's collateral worth at resolution
    uint256 totalDebt;                 // User's debt including spread interest
    uint256 netPosition;               // collateralValue - totalDebt (can be negative)
    uint256 redeemableAmount;          // What user can actually redeem
}
```

### Implementation Strategy

#### Phase 1: Market Resolution (Week 1-2)

```solidity
function resolveMarket(
    MarketResolutionInput memory input
) external onlyAuthorized {
    Storage.$ storage $ = Storage.f();
    Storage.RiskParams memory rp = $.riskParams;
    
    // Validation
    require(block.timestamp >= rp.maturityDate, "Market not mature");
    require(!$.resolutions[marketId].isResolved, "Already resolved");
    
    // Update all indices one final time
    _finalizeIndices();
    
    // Store resolution data
    Storage.MarketResolution storage resolution = $.resolutions[marketId];
    resolution.isResolved = true;
    resolution.resolutionTimestamp = input.resolutionTimestamp;
    resolution.predictionTokenFinalValue = input.finalPredictionTokenPrice;
    resolution.finalPolynanceIndex = reserve.liquidityIndex;
    
    // Calculate settlement amounts
    SettlementCalculation memory settlement = _calculateSettlement(input);
    
    // Handle protocol surplus/deficit
    _handleProtocolBalance(settlement);
    
    emit MarketResolved(marketId, input.finalPredictionTokenPrice);
}
```

#### Phase 2: User Position Settlement (Week 2-3)

```solidity
function calculateUserRedemption(
    address user
) external view returns (UserRedemptionData memory redemption) {
    // Get user position
    Storage.UserPosition memory position = getUserPosition(marketId, user);
    
    // Calculate collateral value at resolution
    uint256 collateralValue = position.collateralAmount
        .mulDiv(resolution.predictionTokenFinalValue, RAY)
        .mulDiv(10**rp.supplyAssetDecimals, 10**rp.collateralAssetDecimals);
    
    // Calculate total debt including spread interest
    (uint256 totalDebt, , ) = Core.calculateUserTotalDebt(
        Core.CalcUserTotalDebtInput({
            principalDebt: _getAaveDebtAtResolution(position),
            scaledPolynanceSpreadDebtPrincipal: position.scaledDebtBalance,
            initialBorrowAmount: position.borrowAmount,
            currentPolynanceSpreadBorrowIndex: resolution.finalPolynanceIndex
        })
    );
    
    // Calculate net position
    redemption.collateralValue = collateralValue;
    redemption.totalDebt = totalDebt;
    
    if (collateralValue >= totalDebt) {
        // User is in profit
        redemption.netPosition = collateralValue - totalDebt;
        redemption.redeemableAmount = redemption.netPosition;
    } else {
        // User lost more than collateral worth
        redemption.netPosition = 0;
        redemption.redeemableAmount = 0;
    }
}
```

#### Phase 3: Redemption Mechanism (Week 3-4)

```solidity
function redeemBorrowerPosition(address borrower) external {
    require(resolution.isResolved, "Market not resolved");
    
    UserRedemptionData memory redemption = calculateUserRedemption(borrower);
    Storage.UserPosition storage position = getUserPosition(marketId, borrower);
    
    // Clear position
    position.collateralAmount = 0;
    position.borrowAmount = 0;
    position.scaledDebtBalance = 0;
    position.scaledDebtBalancePrincipal = 0;
    
    // Transfer redeemable amount if any
    if (redemption.redeemableAmount > 0) {
        IERC20(rp.supplyAsset).safeTransfer(borrower, redemption.redeemableAmount);
    }
    
    emit BorrowerPositionRedeemed(borrower, redemption.redeemableAmount);
}

function redeemSupplyPosition(uint256 tokenId) external {
    require(resolution.isResolved, "Market not resolved");
    require(ownerOf(tokenId) == msg.sender, "Not owner");
    
    Storage.SupplyPosition memory position = $.supplyPositions[tokenId];
    
    // Calculate total LP value including spread earnings
    (uint256 totalWithdrawable, uint256 aaveInterest, uint256 polynanceInterest) = 
        Core.calculateSupplyPositionValue(
            Core.CalcSupplyPositionValueInput({
                position: position,
                currentLiquidityIndex: resolution.finalPolynanceIndex,
                principalWithdrawAmount: _getAaveSupplyAtResolution(position)
            })
        );
    
    // Account for any protocol deficit (pro-rata reduction)
    uint256 adjustedWithdrawable = _applyDeficitAdjustment(totalWithdrawable);
    
    // Clear position and transfer
    delete $.supplyPositions[tokenId];
    IERC20(rp.supplyAsset).safeTransfer(msg.sender, adjustedWithdrawable);
    
    emit SupplyPositionRedeemed(msg.sender, tokenId, adjustedWithdrawable);
}
```

## Development Strategy & Timeline

### Week 1: Foundation & Resolution Logic
**Goal**: Implement core market resolution mechanism

**Tasks**:
1. **Market Resolution Structure**
   ```solidity
   // Add to Storage.sol
   struct MarketResolution {
       bool isResolved;
       uint256 resolutionTimestamp;
       uint256 finalPolynanceIndex;
       uint256 predictionTokenFinalValue;
       uint256 totalRedeemed;
       uint256 protocolDeficit;  // If collateral < total debt
       uint256 protocolSurplus;  // If collateral > total debt
   }
   ```

2. **Oracle Integration**
   - Implement price fetching from prediction market oracle
   - Add price validation and timing constraints
   - Handle edge cases (no trading, manipulation, etc.)

3. **Index Finalization**
   - Final update of all interest indices
   - Lock indices at resolution timestamp
   - Prevent further borrowing/supplying

### Week 2: Settlement Calculations
**Goal**: Build robust settlement math

**Tasks**:
1. **Global Settlement Calculation**
   ```solidity
   function _calculateGlobalSettlement() internal returns (SettlementCalculation memory) {
       // Calculate total collateral value
       uint256 totalCollateralValue = reserve.totalCollateral
           .mulDiv(resolution.predictionTokenFinalValue, RAY);
       
       // Calculate total debt (principal + Aave interest + spread)
       uint256 totalDebtValue = _calculateTotalSystemDebt();
       
       // Determine surplus/deficit
       if (totalCollateralValue >= totalDebtValue) {
           return SettlementCalculation({
               totalCollateralValue: totalCollateralValue,
               totalDebtToSettle: totalDebtValue,
               protocolSurplus: totalCollateralValue - totalDebtValue,
               protocolDeficit: 0
           });
       } else {
           return SettlementCalculation({
               totalCollateralValue: totalCollateralValue,
               totalDebtToSettle: totalDebtValue,
               protocolSurplus: 0,
               protocolDeficit: totalDebtValue - totalCollateralValue
           });
       }
   }
   ```

2. **User-Level Settlement**
   - Calculate individual user net positions
   - Handle underwater positions (debt > collateral value)
   - Implement pro-rata deficit sharing for LPs

3. **Edge Case Handling**
   - Zero-value prediction tokens
   - Rounding errors in calculations
   - Gas optimization for large user bases

### Week 3: Redemption Implementation
**Goal**: Enable users to redeem positions

**Tasks**:
1. **Borrower Redemption**
   - Settle debt against collateral value
   - Return excess to profitable borrowers
   - Clear positions completely

2. **LP Redemption**
   - Calculate final LP value (principal + Aave yield + spread earnings)
   - Apply deficit adjustments if needed
   - Burn NFT positions

3. **State Management**
   - Prevent double redemptions
   - Update global accounting
   - Emit comprehensive events

### Week 4: Testing & Optimization
**Goal**: Ensure robust, secure, gas-efficient implementation

**Tasks**:
1. **Comprehensive Testing**
   ```solidity
   // Test scenarios:
   // - Profitable prediction markets (collateral > debt)
   // - Losing prediction markets (collateral < debt)
   // - Edge cases (zero values, rounding)
   // - Gas optimization tests
   // - Multiple user redemption scenarios
   ```

2. **Security Auditing**
   - Reentrancy protection
   - Integer overflow/underflow checks
   - Access control validation
   - State consistency verification

3. **Gas Optimization**
   - Batch operations where possible
   - Optimize storage reads/writes
   - Use efficient data structures

## Key Design Decisions

### 1. Settlement Model: "Socialized Loss" vs "Individual Loss"
**Chosen**: Individual Loss Model
- Each borrower's loss is limited to their collateral
- LPs absorb system deficit pro-rata
- More predictable for borrowers, spreads systemic risk

### 2. Redemption Timing: "Immediate" vs "Grace Period"
**Chosen**: Immediate with Grace Period
- Immediate redemption available post-resolution
- Grace period for technical issues/disputes
- Emergency pause functionality

### 3. Deficit Handling: "Insurance Fund" vs "Pro-rata Reduction"
**Chosen**: Pro-rata Reduction
- LPs share deficit proportionally
- No additional complexity of insurance fund
- Aligns incentives (LPs price risk appropriately)

## Risk Considerations

### Technical Risks
1. **Oracle Manipulation**: Use multiple oracles, time-weighted prices
2. **MEV Attacks**: Implement commit-reveal or time delays
3. **Precision Loss**: Use Ray math consistently, round in protocol favor

### Economic Risks
1. **Bank Run**: Implement gradual settlement if needed
2. **Deficit Spirals**: Cap maximum LTV ratios appropriately
3. **Oracle Failures**: Have fallback resolution mechanisms

### Operational Risks
1. **Gas Costs**: Optimize for reasonable redemption costs
2. **User Experience**: Clear documentation and UI for settlement
3. **Dispute Resolution**: Admin functions for edge cases

## Integration Points

### Existing System Integration
1. **Core Library**: Extend with settlement calculations
2. **Storage**: Add resolution state tracking
3. **Events**: Add resolution and redemption events
4. **Access Control**: Add resolver role management

### External Dependencies
1. **Prediction Market Oracle**: Price feed integration
2. **Aave Protocol**: Final debt/supply calculations
3. **Frontend**: Settlement UI and user communications

This strategy provides a comprehensive, phased approach to implementing the critical MarketResolveLogic while maintaining system security and user trust.