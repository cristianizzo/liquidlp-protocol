# Task: Whitepaper Updates — Missing Mechanisms

**Priority:** Medium
**Type:** Documentation
**PR:** Standalone

## Overview

Several implemented mechanisms are missing from the whitepaper. This task groups all whitepaper-only updates into one PR.

---

## 1. Add V3 Fee-Only Liquidation Path (Section 7)

**Status:** Implemented in code, missing from whitepaper.

When a V3 NFT position has **zero liquidity but uncollected trading fees**, the protocol can still liquidate by collecting fees only (no `decreaseLiquidity` needed).

### Content to add after "Atomic Liquidation Flow" in Section 7:

```
### V3 Fee-Only Liquidation (Zero Liquidity)

When a Uniswap V3 position has been fully unwound (liquidity == 0) but still has
uncollected trading fees and outstanding debt:

1. LiquidationEngine detects `totalLiquidity == 0 && pos.tokenId > 0`
2. Adapter calls `collectFees()` on the NFT — no `decreaseLiquidity` needed
3. Proportional seizure of collected fees based on debt ratio
4. Protocol fee deducted from seized amount
5. Remaining fees sent to liquidator
6. Debt repaid or written off as bad debt

This path ensures no position can avoid liquidation by having its liquidity
removed but leaving fees uncollected.
```

---

## 2. Add 50% Partial Liquidation Cap (Section 7)

**Status:** Implemented in code, missing from whitepaper.

The whitepaper only mentions 100% liquidation for HF < 0.95 but never documents the default 50% cap for normal liquidations. This matches Aave V3's close factor exactly.

### Content to add to Section 7 (after Health Factor formula):

```
### Partial Liquidation Cap (Aave V3 Pattern)

| Health Factor | Max Liquidation | Rationale |
|---|---|---|
| 0.95 ≤ HF < 1.0 | 50% of debt | Partial liquidation — gives borrower a chance to recover |
| HF < 0.95 | 100% of debt | Full liquidation — position is critically underwater |

The 50% default (`maxLiquidationPortion`) is configurable by POOL_ADMIN
within 10-100% bounds. This matches Aave V3's `DEFAULT_LIQUIDATION_CLOSE_FACTOR`.
```

---

## 3. Fix Section 5 LiquidationEngine Description ✅

**Status:** Completed — updated to remove stale "swap to borrow asset" reference and reflect actual flow.

---

## Acceptance Criteria

- [x] V3 fee-only liquidation documented in Section 7
- [x] 50% partial liquidation cap documented in Section 7
- [x] Section 5 description matches Section 7 (already done)
- [x] No contradictions between sections
- [x] Proofread for consistency with Aurelia branding
- [x] FlashloanLiquidator marked as "Planned" (not yet implemented)
