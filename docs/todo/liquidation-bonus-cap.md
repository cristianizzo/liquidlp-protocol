# Task: Tighten Liquidation Bonus Cap in Code

**Priority:** High
**Type:** Bug/Security — Code Fix
**PR:** Standalone

## Problem

The whitepaper (Section 8) documents liquidation bonuses ranging 3-10% across LP types. However, `Market.sol` allows up to **20%** (`_liquidationBonus <= 2000`), which is more permissive than both:

- **Aave V3:** 5-15% range (governance-set per asset, no hard code cap but max observed ~15% for volatile assets like YFI)
- **Revert Lend:** 2-10% dynamic range (`MIN_LIQUIDATION_PENALTY` to `MAX_LIQUIDATION_PENALTY`)

## Proposed Fix

Tighten `MAX_LIQUIDATION_BONUS` from 2000 (20%) to **1500 (15%)**, aligning with Aave V3's upper bound.

This gives governance enough room for exotic/memecoin pairs (whitepaper shows 10% for these) while preventing misconfiguration above industry norms.

### Code Change

**File:** `src/markets/Market.sol`

```solidity
// Before:
require(_liquidationBonus <= 2000, "BONUS_TOO_HIGH");

// After:
uint256 public constant MAX_LIQUIDATION_BONUS = 1500; // 15% — aligned with Aave V3 upper bound
require(_liquidationBonus <= MAX_LIQUIDATION_BONUS, "BONUS_TOO_HIGH");
```

## Acceptance Criteria

- [x] `MAX_LIQUIDATION_BONUS` constant added (1500 = 15%)
- [x] Existing tests still pass (current configs are all ≤ 10%)
- [x] New test: setting bonus to 16% reverts
- [x] New test: setting bonus to 15% succeeds
- [x] `forge fmt` clean
- [x] Update whitepaper Section 8 to note the 15% hard cap
