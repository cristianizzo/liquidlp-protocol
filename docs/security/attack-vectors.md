# LiquidLP — Attack Vector Analysis & Mitigation Plan

> Last updated: July 2026

---

## Overview

This document maps all known attack vectors against the LiquidLP protocol, references real-world exploits, documents how top protocols defend against them, and tracks our mitigation status.

**Protocol context:** DAO-controlled via OZ TimelockController (48h delay on structural changes). Risk parameters (LTV, haircut, borrow caps) are instant via RISK_ADMIN. Emergency pause is instant via EMERGENCY_ADMIN.

---

## Tier 1: Code Changes Required

### A. Bad Debt Cleanup — Deficit Tracking

**Attack:** One token crashes to $0 (LUNA-style). Collateral becomes worthless. Liquidation can't recover full debt. Remaining debt stays on books forever, accruing phantom interest.

**Real-world:** LUNA/UST crash (May 2022), Aave CRV bad debt (Nov 2022, ~$1.7M)

**How others defend:**
- **Aave V3.3:** During liquidation, if position ends with zero collateral + non-zero debt → debt is burned, recorded as `deficit` on the reserve. `eliminateReserveDeficit()` covers it using slashed Umbrella aTokens.
- **Morpho Blue:** Bad debt socialized — `totalAssets` decreases, all lender shares redeem for proportionally less. Loss isolated to specific market.
- **Compound V3:** `totalReserves` absorb bad debt. Governance injects funds if needed.

**Current status:** IMPLEMENTED (PR #29)

**Implementation:**
- `uint256 public deficit` in `Market.sol`
- In `LiquidationEngine.liquidate()`: after full liquidation, if position has zero collateral + remaining debt → burn debt, increment `market.deficit`
- `eliminateDeficit()` in `Market.sol` — uses `protocolReserves` to cover deficit. Callable by RISK_ADMIN (instant, risk-reducing).
- If `protocolReserves < deficit`: partial coverage, remainder stays tracked
- DAO can vote to inject funds or socialize remaining deficit across lenders (future)

**Governance:** RISK_ADMIN can trigger `eliminateDeficit()` immediately. DAO can vote to inject additional funds via timelock.

---

### B. Frozen Market State

**Attack:** Token depegs (USDC $0.88) or token transfers pause (USDT). Full protocol pause blocks liquidations → bad debt accumulates. Need a "frozen" state that blocks new risk-taking but allows risk-reducing actions.

**Real-world:** USDC depeg (Mar 2023) — Aave Guardian froze reserves, set LTV=0. Aave Kelp exploit (Apr 2026) — $5B frozen.

**How others defend:**
- **Aave V3:** Frozen reserve = no new supply/borrow, but withdraw/repay/liquidate still work. Separate from full pause. Guardian can freeze individual reserves instantly.
- **Compound V3:** `isSupplyPaused` / `isBorrowPaused` / `isWithdrawPaused` — granular per-action pause flags.

**Current status:** IMPLEMENTED (PR #29) — CircuitBreaker.freezeMarket() blocks deposit/borrow/addCollateral, allows withdraw/repay/liquidate. Note: Market.supply() (lender deposits) is intentionally NOT blocked during freeze — more lender liquidity helps during incidents.

**Implementation:**
- `CircuitBreaker.freezeMarket()` / `unfreezeMarket()` with `marketFrozen` mapping
- When frozen:
  - Block: `deposit()`, `borrow()`, `addCollateral()`
  - Allow: `withdraw()`, `repay()`, `liquidate()`, `supply()` (lender deposits help during incidents)
- Checked in `PositionManager.deposit()`, `PositionManager.addCollateral()`, `LendingEngine.borrow()`
- `freezeMarket()` callable by EMERGENCY_ADMIN, KEEPER, or POOL_ADMIN (instant)
- `unfreezeMarket()` callable by POOL_ADMIN only (through timelock)

**Governance:** EMERGENCY_ADMIN/KEEPER can freeze instantly. Unfreezing requires POOL_ADMIN (48h timelock), preventing premature unfreeze after exploit.

---

### C. Fallback Oracle — Chainlink Outage

**Attack:** Chainlink feed goes down entirely. All price reads revert. Positions can't be valued → liquidations fail → bad debt accumulates silently.

**Real-world:** Chainlink temporarily halted LUNA/USD feed during crash. Several DeFi protocols couldn't liquidate positions.

**How others defend:**
- **Aave V3:** Governance-configured fallback oracle per asset. If primary fails, fallback is used.
- **Euler V2:** Multiple oracle providers (Chainlink, Chronicle, Pyth, Redstone). Each adapter has type-specific validation.
- **Chainlink best practice:** Use `try/catch` around `latestRoundData()` to handle reverts gracefully.

**Current status:** NOT IMPLEMENTED — Chainlink failure = revert = no liquidation

**Plan:**
- In `UniswapV3Oracle._getChainlinkPrice()`: wrap in `try/catch`. If Chainlink reverts or returns stale data, fall back to TWAP-only pricing with a higher haircut (e.g., +10% additional haircut).
- Add `bool public chainlinkFallbackEnabled` (default: true). RISK_ADMIN can toggle.
- Add `uint256 public fallbackHaircutBps` (default: 1000 = 10%). RISK_ADMIN configurable.
- When in fallback mode: emit `ChainlinkFallbackActivated(token, timestamp)` event for off-chain monitoring.
- Same pattern for `UniswapV2Oracle`.
- `PriceFeedRegistry.getPrice()`: wrap Chainlink call in try/catch, return 0 on failure (callers already handle 0).

**Governance:** RISK_ADMIN can enable/disable fallback and set fallback haircut. No timelock needed (risk-reducing action).

---

### D. Max Interest Rate Cap

**Attack:** Extreme utilization (99%+) causes interest rate to spike. If governance misconfigures IRM slopes, rate could be absurdly high. Large `elapsed` time in `accrueInterest()` (e.g., no one calls it for days) causes massive single-call interest accrual.

**Real-world:** Not exploited yet, but Compound V3 and Aave V3 both cap rates. Aave's slope2 of 300%+ at 100% utilization is a deterrent, not a vulnerability — but an uncapped rate IS a vulnerability.

**How others defend:**
- **Compound V3:** Explicit cap on per-second rate. `baseBorrowRate + slopeRate` bounded.
- **Aave V3:** slope2 set by governance, typically 60-300%. No explicit max but IRM parameters are governance-controlled.

**Current status:** IMPLEMENTED (PR #29) — `InterestRateModel.MAX_RATE_PER_SECOND` caps at ~500% APR.

**Plan:**
**Implementation:**
- `InterestRateModel.MAX_RATE_PER_SECOND = 158_548_959_919` (≈ 500% APR)
- `getBorrowRate()` clamps return value to `MAX_RATE_PER_SECOND`
- Constant in code, not governance-configurable — absolute safety rail.

**Governance:** Not configurable. Even DAO can't exceed this ceiling.

---

## Tier 2: Tests Required (Existing Defenses, Missing Coverage)

### 1. Chainlink Returns 0 / Stale

**Defense exists:** `require(answer > 0)` + `maxStaleness` check in both oracles + PriceFeedRegistry.

**Test needed:** Mock Chainlink returning 0 → verify positions become liquidatable. Mock stale feed (>1h old) → verify `STALE_PRICE` revert. Verify protocol doesn't freeze when one feed is stale.

---

### 2. Token Depeg (USDC at $0.88)

**Defense exists:** Oracle reflects real Chainlink price. Health factor drops accordingly.

**Test needed:** Mock USDC Chainlink at $0.88 → verify HF drops proportionally → liquidation triggers. Verify lenders' share value reflects the depeg.

---

### 3. Token Crashes to $0

**Defense exists:** Oracle returns 0 → HF = 0 → position is fully liquidatable (CRITICAL_HF_THRESHOLD).

**Test needed:** Mock token price to $0 → verify mass liquidation. Verify bad debt scenario (collateral = 0 but debt remains). This test will fail until Tier 1 item A (deficit tracking) is implemented.

---

### 4. Flash Loan Price Manipulation

**Defense exists:** 30-min TWAP + Chainlink cross-validation (3% max deviation) + borrow cooldown (1+ blocks).

**Test needed:** Verify TWAP is immune to single-block price manipulation. Verify cross-validation rejects large deviations. Verify borrow cooldown prevents same-block deposit+borrow.

---

### 5. Double-Deposit V3 NFT

**Defense exists:** Adapter transfers NFT to its own custody. Second deposit would fail (user no longer owns NFT).

**Test needed:** Deposit NFT → try depositing same NFT again → verify `TRANSFER_FAILED` revert.

---

### 6. 100% Utilization

**Defense exists:** Kinked IRM makes high utilization expensive. Withdrawal checks actual balance.

**Test needed:** Borrow until 99% utilization → verify rate spikes. Verify lender withdrawal blocked when no liquidity. Verify new borrows at 100% utilization behavior.

---

### 7. Self-Liquidation

**Defense exists:** Allowed by design (same as Aave). No storage aliasing vulnerability because collateral (LP) and debt (USDC) are separate assets.

**Test needed:** Owner liquidates own position → verify no profit beyond normal liquidation mechanics. Verify it's economically equivalent to manual unwind + repay.

---

### 8. Token Transfer Pause (USDT)

**Defense exists:** SafeERC20 reverts cleanly on failed transfer.

**Test needed:** Mock pausable token → deposit LP with that token → attempt liquidation → verify clean revert (not stuck state). Verify protocol recovers when token unpauses.

---

### 9. borrowIndex Extreme Duration

**Defense exists:** uint256 RAY scale (won't overflow for practical durations).

**Test needed:** Simulate 10 years at 100% APR → verify no overflow. Simulate 50 years at 10% APR → verify precision is acceptable.

---

### 10. Keeper Offline — Circuit Breaker Not Triggered

**Defense exists:** PriceValidator + PoolHealthMonitor have KEEPER role. CircuitBreaker is manual backup.

**Test needed:** Simulate oracle anomaly without keeper calling validatePrice → verify positions are still liquidatable (circuit breaker doesn't fire, but liquidation still works based on HF).

---

## Tier 3: Design Decisions (Future)

| # | Feature | Notes | Governance |
|---|---|---|---|
| 1 | **Deferred liquidation** for paused tokens | No protocol has solved this. Mark position as "seized", settle when transfers resume. | POOL_ADMIN via timelock |
| 2 | **Utilization cap** (99.5% max) | Block borrowing above threshold. Ensures minimum withdrawal liquidity. | RISK_ADMIN configurable |
| 3 | **Emergency IRM override** | Allow governance to change rates without deploying new IRM contract. | RISK_ADMIN instant for safer changes |
| 4 | **Bad debt socialization** | If reserves insufficient to cover deficit, socialize across lenders (Morpho pattern). | DAO vote via timelock |
| 5 | **Multi-oracle support** | Add Pyth/Redstone as additional oracle sources (Euler V2 pattern). | POOL_ADMIN via timelock |

---

## References

### Exploits Referenced
- **LUNA/UST crash** (May 2022) — $40B collapse, Chainlink feed halted
- **Aave CRV bad debt** (Nov 2022) — ~$1.7M bad debt from Avi Eisenberg's CRV short
- **USDC depeg** (Mar 2023) — dropped to $0.88, Aave froze reserves
- **Euler V1 hack** (Mar 2023) — $197M, oracle + liquidation flaw
- **Impermax V3 hack** (Apr 2025) — $300K, flash loan fee manipulation
- **Impermax V3 hack #2** (Nov 2025) — $380K, collateral fee valuation flaw
- **Revert Lend Aerodrome exploit** (Jan 2026) — $50K, GaugeManager collateral bypass
- **Aave Kelp exploit** (Apr 2026) — $200M bad debt, tested Umbrella system

### Protocol Defenses Referenced
- **Aave V3/V3.3** — Frozen reserves, deficit tracking, Umbrella safety module
- **Morpho Blue** — Bad debt socialization via share dilution
- **Compound V3** — Rate caps, reserve absorption
- **Euler V2** — Multi-provider oracle with per-feed staleness
