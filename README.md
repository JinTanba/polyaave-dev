# 🔮👻
## Core Concept

PolynanceLend allows users to **borrow traditional assets (like USDC) using prediction market position tokens as collateral**. This is novel because prediction tokens typically have uncertain, time-dependent values that resolve to either 0 or some fixed amount at maturity.

## Key Components

### 1. **Dual-Layer Architecture**
- **Liquidity Layer**: Uses existing lending protocols (Aave V3) as the underlying liquidity source
- **Polynance Layer**: Manages the prediction token collateral and risk parameters on top

### 2. **Main Operations**

**Supply**: 
- Users deposit assets (e.g., USDC) which get supplied to Aave
- Users receive LP tokens representing their share of the pool

**Borrow**:
- Users deposit prediction tokens as collateral
- The protocol values these tokens via an oracle
- Users can borrow up to a certain LTV (loan-to-value) ratio
- The protocol borrows from Aave and passes funds to the user

**Repay**:
- Users repay principal + interest
- Interest has two components:
  - Aave's interest rate (what the protocol pays)
  - Polynance's interest rate (protocol's margin)

**Market Resolution**:
- When prediction markets resolve, the protocol redeems position tokens
- Calculates profit/loss based on redemption value vs outstanding debt
- Handles distribution to lenders and borrowers

### 3. **Risk Management**
- **LTV ratios**: Controls how much can be borrowed against prediction token collateral
- **Dual interest rates**: Both fixed and variable rate modes supported
- **Price oracles**: Values prediction tokens dynamically before resolution
- **Liquidation parameters**: Though liquidation logic isn't fully implemented in this version

## Innovative Aspects

1. **Prediction tokens as collateral**: This is unique because these assets have binary or discrete outcomes and time-dependent values

2. **Interest rate arbitrage**: The protocol can earn spread between what it pays Aave and what it charges borrowers

3. **Resolution mechanism**: Handles the special case where collateral transforms from speculative tokens to resolved assets

4. **Composability**: Built on top of existing DeFi infrastructure (Aave) rather than recreating lending logic

## Current Implementation Status

From the code, it appears this is indeed a beta version with some TODOs:
- Swap functionality after resolution needs implementation
- Full liquidation logic appears incomplete
- LP and loan resolution claim calculations in Core.sol are not yet implemented

This protocol essentially creates a new primitive in DeFi - allowing prediction market participants to access liquidity without selling their positions, while giving lenders exposure to prediction market yields.



# design concept

This repository applies the **Functional Core / Imperative Shell** architecture. All protocol behaviour is defined once, inside a **single Core library** written entirely with **`pure` (and `view`) functions**. Every public‐facing contract simply gathers state, calls the Core, and stores the result.

---

## 1 · Architectural Sketch

```
┌─────────────── Application Layer ───────────────┐
│  Front‑end · SDK · Bot …                        │
└──────────────────────▲──────────────────────────┘
                       │ external calls
┌──────────────────────┴──────────────────────────┐
│  Imperative Shell (stateful contracts)          │
│  • read storage                                  │
│  • call Core                                     │
│  • write storage · emit events                   │
└──────────────────────▲──────────────────────────┘
                       │ internal
┌──────────────────────┴──────────────────────────┐
│  **Core Library** (single file)                 │
│  • 100 % deterministic                          │
│  • business rules = behaviour                   │
│  • accepts/returns only structs & value types   │
└──────────────────────────────────────────────────┘
```

---

## 2 · Core Library Mandate

1. **One file only** –  `CoreLib.sol`.
2. **Pure logic only** – no storage access, external calls, timestamps, or events.
3. **Struct‑first API** – every function receives **exactly one** `struct` argument and returns value types (or another struct). No loose tuples.
4. **Behaviour declaration** – the Core is the single source of truth for pricing, interest accrual, liquidation rules, quota checks, etc.

> Example
>
> ```solidity
> library CoreLib {
>     using WadRayMath for uint256;
>
>     struct AccrualParams {
>         uint256 principal; // 1e18
>         uint256 indexPrev; // 1e27
>         uint256 indexNow;  // 1e27
>     }
>
>     function accrue(AccrualParams memory p)
>         internal pure returns (uint256)
>     {
>         return p.principal.rayMul(p.indexNow) / p.indexPrev;
>     }
> }
> ```

---

## 3 · Directory Layout

```
/contracts
  ├─ CoreLib.sol       # ← pure logic (single file)
  └─ modules/          # shell contracts (Pool, Vault, Router …)
```

---

## 4 · Implementation Rules

| Topic         | Rule                                         |
| ------------- | -------------------------------------------- |
| Naming        | `CoreLib.sol` only                           |
| Visibility    | `internal` for all Core functions            |
| Units         | Use Wad (`1e18`) / Ray (`1e27`) consistently |
| Safe casting  | Always via `SafeCast`                        |
| Zero‑division | Guard with `require(y != 0)` before division |

---

## 5 · Development Flow

1. **Define maths in Core** – add/modify `CoreLib.sol`.
2. **Shell integration**   – load state → call Core → store.
3. **Review & merge**     – Core diff must be deterministic and gas‑checked.

---

## 6 · Versioning

* **MAJOR** – Behaviour change (function signature or formula).
* **MINOR** – New pure function added.
* **PATCH** – Internal refactor or gas optimisation.

---

Maintainers: @LeadDev · @ProtocolEngineer
Last update: 2025‑05‑31
