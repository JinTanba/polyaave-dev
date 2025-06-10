# Conditional Tokens Index

**Repository contents**

| File                                | Role                                                                                                                                                                                                                         |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BaseConditionalTokenIndex.sol`     | Abstract ERC-20 that encapsulates a basket of Gnosis **Conditional Tokens** (CTF position IDs). Implements mint / burn (`deposit`, `withdraw`) and encodes every invariant in *immutable args* stored inside the proxy code. |
| `ConditionalTokensIndex.sol`        | Thin concrete implementation of `BaseConditionalTokenIndex`. It does **not** add logic – letting integrators inherit and extend if required.                                                                                 |
| `ConditionalTokensIndexFactory.sol` | Deterministic factory that builds minimal-proxy instances of an index, validates the basket, and supports **merge** / **split** operations between existing indexes.                                                         |

---

## 1. Motivation

Prediction market position tokens with sufficient liquidity are clearly valuable assets. However, they are extremely difficult to handle due to issues such as becoming worthless in an instant, being ERC-1155 tokens, or having too many tokens.
Bundling position tokens and treating them as index tokens could be a good option. We believe this would resolve most of the issues.
[Gnosis's CTF](https://github.com/gnosis/pm-contracts) is an excellent technology—simple yet highly compatible with a wide range of possibilities—so we believe it can also be implemented in a straightforward manner.

---

## 2. Architecture

```text
          ┌────────────────────────────┐
          │  ConditionalTokensIndex    │  (implementation contract)
          └────────────────────────────┘
                         ▲
      cloneDeterministicWithImmutableArgs()
                         │
 ┌────────────────────────────────────────────────────┐
 │  Minimal-proxy Index Instance                      │
 │  ─ contains immutable args:                        │
 │    • uint256[] components     ← CTF position IDs   │
 │    • bytes32[] conditionIds                        │
 │    • uint256[] indexSets                          │
 │    • bytes   specifications  ← arbitrary metadata │
 │    • address factory / ctf / collateral / impl    │
 └────────────────────────────────────────────────────┘
                         ▲
                         │
          ┌────────────────────────────┐
          │ ConditionalTokensIndexFactory │
          └────────────────────────────┘
```

* **Deterministic address**
  The factory encodes the basket (immutable args), hashes it, and uses the hash as the `salt`.
  → *Same basket ⇒ same index address.*

* **Storage-in-code**
  The proxy stores all basket parameters in the contract’s **code section** (via `Clones.fetchCloneArgs`).
  The base contract exposes cheap getters (`components()`, `conditionIds()`, etc.) that read this data with `extcodecopy`, so **no storage slots** are consumed for immutable data.

---

## 3. Invariants enforced by the Factory

1. `components.length == conditionIds.length == indexSets.length`.
2. Every `conditionId` appears **exactly once** inside an index (prevents double counting).
3. `indexSet` is non-zero and `< 2^outcomeSlotCount`.
4. Positions are **sorted ascending** to make the deterministic address unique.
5. During `createIndex` the caller funds each component with `funding` units; the factory verifies that the freshly minted index token balance equals `funding`.

Violations revert with typed custom errors (`LengthMismatch`, `InvalidIndexSet`, …).

---

## 4. External APIs

### BaseConditionalTokenIndex

| Function                                                                                   | Description                                                                  |
| ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| `deposit(uint256 amount)`                                                                  | Caller transfers *amount* of **each** component → index tokens minted 1 : 1. |
| `withdraw(uint256 amount)`                                                                 | Burns index tokens and returns `amount` of each component.                   |
| `components()` / `conditionIds()` / `indexSets()`                                          | Immutable basket description.                                                |
| `encodedSpecifications()`                                                                  | Arbitrary off-chain metadata bytes supplied when the index was created.      |
| Standard ERC-20 (`transfer`, `approve`, etc.) and ERC-1155 receiver hooks are implemented. |                                                                              |

### ConditionalTokensIndexFactory

| Function                                                                 | Purpose                                                                             |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| `createIndex(IndexImage image, bytes initData, uint256 funding)`         | Deploy a new index and seed it with *funding* units of each position.               |
| `mergeIndex(impl, specs, initData, address[] indexList, uint256 amount)` | Burns `amount` units of N existing indexes, re-mints them into a **merged** basket. |
| `predictDeterministicAddressWithImmutableArgs` (via `computeIndex`)      | Pure address calculation without on-chain deployment.                               |
| `composeIndex`                                                           | Internal helper that validates and encodes the immutable args.                      |

> **Note** `splitIndex` is stubbed but not yet implemented – implementers can mirror the merge logic.


---

## 6. Extending the Index

1. **Override `_init(bytes)`** in a custom contract that inherits `BaseConditionalTokenIndex` to hook in fee logic, whitelist checks, etc.
2. Pass the new implementation address in `IndexImage.impl` when calling the factory.

All invariants and deterministic address rules remain unchanged because the basket data lives in the proxy’s bytecode, not in the child contract.

---

## 7. Gas & Security Notes

* **No storage writes** on read-only getters → extremely cheap basket introspection.
* Mint / burn flow uses `safeBatchTransferFrom`, so the index never holds stale approval allowances.
* ERC-165 is implemented; interfaces (`IERC1155Receiver`, custom index interface) can be discovered.
* Because the basket is immutable, a compromised implementation **cannot** silently change its constituents – it would need a new deployment, producing a new address.

---

## 8. License

All contracts are released under **MIT**.
