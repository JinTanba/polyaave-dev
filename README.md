# 👻🔮
---

## App
A: https://interfaces-steel.vercel.app/
B: https://polyindex-factory.vercel.app/
## 1. Big picture

PolynanceLend is a **single-market lending pool** that marries three elements:

| Element                               | Role in PolynanceLend                                                                                                                               |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Aave v3 Money-Market**              | Base yield engine. 100 % of supplied stable-assets are flash-deposited into Aave, earning its variable deposit APY.                                 |
| **Prediction-market tokens** (ERC-20) | Accepted as collateral. Each pool is hard-wired to one “YES/NO” outcome token and one supply asset (e.g. USDC).                                     |
| **Polynance spread layer**            | Adds an adjustable spread on top of Aave’s borrow rate. The spread is where Polynance captures risk premium, protocol fee, and additional LP yield. |

The result is a **“lending wrapper around prediction markets.”**  Liquidity providers (LPs) supply stable-coins, borrowers pledge outcome tokens to obtain working capital, and settlement happens automatically when the underlying market resolves.

---

## 2. Key actors & tokens

| Actor             | What they deposit                                                      | What they receive                                                                                                    |
| ----------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **LP (supplier)** | `supplyAsset` (e.g. USDC)                                              | NFT **Supply Position** (ERC-721) representing their deposit. Balance grows with (Aave APY + Polynance supply rate). |
| **Borrower**      | `collateralAsset` (prediction token)                                   | Up-front transfer of `supplyAsset`, plus a debt position recorded on-chain.                                          |
| **Curator**       | Market admin address (sets oracle, maturity date, can trigger resolve) | No economic token; earns no spread — purely operational.                                                             |
| **Protocol**      |                                                                        | Retains a slice of spread interest via `reserveFactor` (bps).                                                        |

---

## 3. Interest-rate model

All rates are calculated in **Ray precision** (1 Ray = 1 × 10²⁷).

### 3.1 Utilisation

$$
U \;=\; \frac{\text{totalBorrowedPrincipal}}{\text{totalPolynanceSupply}}
$$

### 3.2 Spread paid by borrowers

Piece-wise linear around an *optimal utilisation* point:

$$
\text{Spread}(U)=
\begin{cases}
\text{baseSpreadRate}+U\times\text{slope1}, & U\le U_{\*}\\
\text{baseSpreadRate}+U_{\*}\,\text{slope1}+(U-U_{\*})\,\text{slope2}, & U>U_{\*}
\end{cases}
$$

Parameters are stored in `Storage.RiskParams`:

| Parameter            | Meaning                               | Typical example   |
| -------------------- | ------------------------------------- | ----------------- |
| `baseSpreadRate`     | Minimum markup over Aave (Ray)        | 0.02 Ray (≈ 2 %)  |
| `optimalUtilization` | Target pool usage (Ray)               | 0.8 Ray (80 %)    |
| `slope1`,`slope2`    | Rate steepness below / above $U_{\*}$ | 0.1 Ray / 0.3 Ray |
| `reserveFactor`      | % of spread routed to protocol (bps)  | 1 000 bps (10 %)  |

### 3.3 Borrow APR

$$
\text{APR}_{\text{borrow}} = \text{AaveVariableBorrowAPR} + \text{Spread}(U)
$$

### 3.4 Supply APR

LPs earn **both** the underlying Aave deposit APY and their pro-rata share of the spread:

$$
\text{APR}_{\text{sup}} = \text{AaveDepositAPR} + \text{Spread}(U)\times U
$$

> *Reserve factor* is netted out before the spread is sent to LPs.

---

## 4. Collateral & risk limits

| Symbol in code         | Description                                     | Typical value |
| ---------------------- | ----------------------------------------------- | ------------- |
| `ltv`                  | Maximum borrow as % of collateral value (bps)   | 70 %          |
| `liquidationThreshold` | HF = 1 trigger (bps)                            | 75 %          |
| `lpShareOfRedeemed`    | % of excess collateral routed to LPs at resolve | 20 %          |

### 4.1 Collateral valuation

`priceOracle` (externally injected) returns collateral price in Ray.
Value is normalised to the supply-asset decimals inside `Core.calculateMaxBorrow`.

### 4.2 Health factor

$$
HF = \frac{\text{Collateral Value}\times\text{liquidationThreshold}}{\text{Debt}}
$$

Liquidation occurs when $HF<1$.  (Liquidation flow yet to be wired – placeholder for v1.)

---

## 5. Lifecycle of a market

1. **Pool creation** – Deployer sets `RiskParams` (assets, oracle, maturityDate, rate slopes, etc.). Pool is inactive until the curator flips `isActive`.
2. **Supply** –

   * LP deposits USDC → tokens are *immediately* forwarded to Aave.
   * Contract mints an ERC-721 Supply Position whose internal fields store:

     * `supplyAmount` (principal)
     * `scaledSupplyBalancePrincipal` (Aave-side principal + Aave interest)
     * `scaledSupplyBalance` (Polynance spread index)
3. **Borrow** –

   * Borrower transfers prediction tokens.
   * `Core.calculateMaxBorrow` enforces LTV.
   * Contract *itself* borrows from Aave, drawing the user’s USDC and sending it to them.
   * Two indices track debt:

     * `scaledDebtBalancePrincipal` (Aave)
     * `scaledDebtBalance` (Polynance spread)
4. **Ongoing accrual** – Every supply/borrow/repay touchpoint updates:

   * `variableBorrowIndex` – cumulative Polynance spread index
   * Aave’s indices are read via `ILiquidityLayer`.
5. **Repay / Withdraw** – Reverse of steps 2–3 including proportional accounting of principal vs interest (see `SupplyLogic.withdrawAll` and `BorrowLogic.repay`).
6. **Maturity & Resolve**

   * After `maturityDate` curator calls `MarketResolveLogic.resolve()`.
   * Prediction tokens are redeemed for USDC (via oracle or on-chain conversion).
   * Flow of funds

     1. **Repay Aave principal debt** for all borrowers (pool-level).
     2. **Excess**

        * If redemption **≥ total debt** → surplus split:

          * `lpShareOfRedeemed` to LP profit pool
          * Remainder to borrowers (pro-rata to their original debt)
        * If redemption **< total debt** → deficit (`marketLoss`) socialised across LP principal.
   * LPs and borrowers call `redeemByLp()` / `redeemByBorrower()` to pull their share.

---

## 6. Cash-flow walk-through (numbers rounded)

| Step                      | Pool totals                                                           | Comments          |
| ------------------------- | --------------------------------------------------------------------- | ----------------- |
| **T0 supply**             | LPs deposit 1 000 000 USDC → Aave                                     | —                 |
| **Pool utilisation 40 %** | Borrowers draw 400 000 USDC, collateral YES-tokens worth 600 000 USDC | HF = 1.5          |
| **Rates (example)**       | Aave deposit 3 %; Aave variable borrow 4 %                            | —                 |
| Spread $U=0.4$            | base 2 % + slope1 10 %×0.4 = 6 %                                      | Borrow APR = 10 % |
| **Projected LP APY**      | 3 % (Aave) + 6 %×0.4 = **5.4 %**                                      | Before fees       |
| **Protocol fee**          | reserveFactor 10 % → 0.54 % captured by DAO                           | —                 |

---

## 7. Protocol revenue

* **Spread fee** – `reserveFactor` % of interest paid above Aave.
* **Liquidation penalty** (future) – share of seized collateral.
* **Idle cash** – none (all funds stay in Aave, minimising utilisation risk).

---

## 8. Risk map & mitigation levers

| Risk                                     | Source                                | Mitigation lever                                                                                   |
| ---------------------------------------- | ------------------------------------- | -------------------------------------------------------------------------------------------------- |
| **Oracle failure / market manipulation** | Wrong collateral price                | Use TWAP + multi-sig curator, small loan caps until liquidity deepens.                             |
| **Prediction market resolves 0**         | Collateral worthless                  | Conservative `ltv`, higher slope2 to discourage high utilisation, socialise loss via `marketLoss`. |
| **Aave insolvency / de-peg event**       | Underlying money market               | Pool supports only high-quality stables; can migrate modules (interface `ILiquidityLayer`).        |
| **Liquidity crunch**                     | High utilisation locks LP withdrawals | Dynamic spread sharply increases above `optimalUtilization`, incentivising repay/supply.           |
| **Smart-contract bug**                   | Solidity code                         | Full suite of unit + fuzz tests, audit before main-net.                                            |

---
