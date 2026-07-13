# Aurelia Protocol — Whitepaper

> Unlock LP positions as collateral. Borrow against your liquidity without removing it.

**Version:** 1.0 | **Date:** July 2026

---

## 1. Abstract

Aurelia is a decentralized lending protocol that unlocks ~$8B in locked LP capital across DeFi. Users deposit their LP positions (Uniswap V3/V2, Curve, Aerodrome, PancakeSwap) as collateral and borrow stablecoins against them — while the LP keeps earning swap fees. The protocol solves two hard technical problems that prevented LP collateral lending before: (1) a manipulation-resistant LP pricing oracle using dual TWAP + Chainlink cross-validation with 5 defense layers, and (2) an atomic liquidation engine where liquidators only deal in stablecoins — never touching LP tokens directly. Built with UUPS upgradeable proxies, Aave-style reserve factor fees, and DAO governance for progressive decentralization.

---

## 2. Problem Statement

### The Locked Capital Problem

Liquidity Providers across DeFi have ~$8B in capital locked in LP positions:

| DEX | Locked LP Capital | Source |
|---|---|---|
| Curve | ~$2.0B | DefiLlama, July 2026 |
| PancakeSwap V2/V3 | ~$1.8B | DefiLlama, July 2026 |
| Uniswap V3/V4 | ~$1.0B | DefiLlama, July 2026 |
| Uniswap V2 | ~$700M | DefiLlama, July 2026 |
| Aerodrome (Base) | ~$500M | DefiLlama, July 2026 |
| QuickSwap | ~$450M | DefiLlama, July 2026 |
| Camelot | ~$200M | DefiLlama, July 2026 |
| SushiSwap | ~$50M | DefiLlama, July 2026 |
| Others | ~$1.3B | Estimated |
| **Total** | **~$8.0B** | |

*Note: TVL figures fluctuate. These represent approximate values as of July 2026 from DefiLlama.*

This capital earns swap fees (2-15% APY) but cannot be used for anything else. LPs cannot borrow against it, leverage it, or use it as collateral in any lending protocol.

### The Lido Analogy

Lido solved this problem for staked ETH: deposit ETH → get liquid stETH → use stETH anywhere in DeFi. Lido grew to ~$15B TVL by unlocking staked capital.

Previous attempts have been limited:

- **Euler V1** accepted LP collateral but was exploited for $197M in March 2023 due to oracle and liquidation flaws.
- **Impermax** — the closest conceptual competitor — supports V2/V3 LP collateral across chains with isolated lending per pair. However, each market is single-pair, single-DEX, with no unified cross-AMM pricing layer.
- **Revert Lend** — accepts Uniswap V3 NFTs as collateral with continuous health monitoring. V3-only, single DEX.
- **YLDR** — Aave fork for V3 LP leverage (up to 70% LTV). Single DEX, liquidators receive LP shares rather than stablecoins.
- **Curve Lend (llamalend)** — native Curve LP lending. Curve-only ecosystem.

No protocol has solved LP collateral lending across multiple DEXes with a unified pricing engine. Each competitor is locked to one AMM type.

The technical barriers are significant — and they explain why:

- **LP positions are complex to price** — each AMM uses fundamentally different math. Uniswap V2 uses constant-product (xy=k), V3 uses concentrated liquidity with tick ranges, Curve uses StableSwap invariants. A single oracle approach cannot accurately price all of them.
- **LP positions are hard to liquidate** — unwinding requires DEX-specific operations (NFT decreaseLiquidity for V3, removeLiquidity via router for V2, multi-token withdrawal for Curve), plus token swaps and slippage management.
- **Oracle manipulation** — naive LP pricing (reading pool reserves) is trivially exploitable via flash loans. Each AMM type requires a different manipulation-resistant pricing method.

Aurelia solves all three with a multi-DEX, purpose-built architecture: type-specific oracles behind a unified interface, DEX-specific adapters behind a common adapter interface, and an atomic liquidation engine where liquidators never touch LP tokens.

---

## 3. Solution Overview

```
User deposits LP position → Protocol locks it → User borrows stablecoins
                                    ↓
                          LP keeps earning swap fees
                          (double capital efficiency)
```

**For LP holders:**
- Deposit LP position from any supported DEX
- Borrow up to 55-85% of LP value (depends on LP type risk)
- LP continues earning swap fees while used as collateral
- Add collateral to improve health factor — send underlying tokens (e.g., WETH + USDC), protocol adds liquidity internally
- Repay debt anytime, withdraw LP

**For lenders:**
- Supply stablecoins (USDC, DAI, etc.) to earn yield
- Interest paid by LP borrowers
- Isolated markets per LP type — risk contained

**For liquidators:**
- Input: USDC. Output: USDC + bonus (3-8%).
- Never touch LP tokens — all unwinding is atomic inside the contract
- Existing liquidation bots work with minimal changes

---

## 4. Competitive Landscape

### Why Not Build on Morpho / Euler V2?

Permissionless lending protocols (Morpho Blue, Euler V2, Silo Finance) allow anyone to create isolated markets with custom collateral. In theory, someone could create an LP collateral market on Morpho today. In practice, they can't — for two reasons:

1. **Liquidation interface mismatch.** Morpho and Euler use a standard liquidation flow: seize collateral, give it to the liquidator. For LP tokens, this means the liquidator receives an opaque LP position (or worse, a Uniswap V3 NFT) they must manually unwind. No liquidation bot does this today. Aurelia's atomic liquidation engine handles the unwinding internally — liquidators only deal in USDC.

2. **Oracle complexity.** These platforms require a single oracle address per collateral type. LP positions require type-specific pricing logic (sqrt(k) for V2, TWAP + tick math for V3, virtual price for Curve) with cross-validation and circuit breakers. This cannot be reduced to a simple Chainlink feed.

Aurelia is purpose-built infrastructure that solves both problems. It could eventually become an oracle + liquidation module for permissionless platforms, but the standalone protocol captures more value and allows tighter integration between oracle, adapter, and liquidation layers.

### Direct Competitors

**Impermax**
~$86K real TVL (V2 on Ethereum), 6 chains. DefiLlama reports ~$819K but on-chain verification shows the V3 product is completely drained (~$175 dust across all chains) after two exploits. The closest conceptual competitor. Supports V2 LP tokens and V2 forks (SushiSwap, QuickSwap, TraderJoe) as its core product, plus a separate "Impermax V3" product for concentrated liquidity via NFTLP wrappers (now empty). Markets are fully isolated per single pair, permissionless, anyone can create one.

- **Oracle:** V2 pricing uses a sqrt(TWAP/spot) method that is mathematically sound for constant-product AMMs — since k = r0 x r1 is invariant to swaps, the price is immune to in-block reserve manipulation. No Chainlink cross-validation, but the math is elegant and works well for V2.
- **Liquidation:** Liquidators receive LP tokens + 4% bonus — they must unwind the LP position themselves. Flash liquidation supported but adds complexity.
- **Security:** Two exploits on Base in 2025, both on the V3 product ($300K flashloan attack in April, $380K collateral fee valuation flaw in November — $680K total). The V2 oracle was never exploited. The V3 failures occurred because concentrated liquidity breaks the sqrt(k) invariant — k is no longer constant when liquidity is concentrated in tick ranges, and Impermax attempted to reuse V2's pricing model for a fundamentally different AMM type.
- **Key lesson:** Impermax proves that solid V2 oracle math cannot simply be extended to V3/Curve/Aerodrome. Each AMM type needs its own pricing model — exactly the problem Aurelia's adapter pattern solves.
- **Key gap:** No unified cross-AMM oracle. No Curve, no Aerodrome. Liquidators deal in LP tokens, not stablecoins.

**Revert Lend** (~$7.4M TVL, 6 chains)
Accepts Uniswap V3 NFTs as collateral. Recently added Aerodrome Slipstream support on Base (positions stay staked in gauge, earning AERO rewards while collateralized). Non-upgradeable contracts.

- **Oracle:** Dual oracle (Chainlink + V3 TWAP with cross-validation) — architecturally similar to Aurelia's approach. A Code4rena audit found a TWAP calculation bug for negative tick deltas that could affect liquidation triggers.
- **Liquidation:** FlashloanLiquidator contract enables atomic liquidation — liquidators effectively deal in stablecoins. Dynamic penalty (2-10%) based on how underwater the position is. Closest to Aurelia's atomic liquidation design.
- **Security:** Code4rena audit ($88.5K bounty pool, 6 high-severity findings). $50K exploit on Base (January 2026) — the Aerodrome GaugeManager allowed withdrawing collateral liquidity during an active loan. This exploit illustrates the risk of bolting on new AMM types without a clean adapter/oracle separation.
- **Key gap:** Limited to V3 + Aerodrome. No V2, no Curve, no PancakeSwap. The Aerodrome exploit shows the difficulty of adding new AMM types to a monolithic architecture.

**Other Competitors**

| Protocol | Coverage | Limitation |
|---|---|---|
| **YLDR** | V3 only | Aave fork, LTV 70%+. Single DEX. Liquidators receive LP shares, not stablecoins. Limited TVL. |
| **Curve Lend** | Curve only | Native llamalend with LLAMMA soft-liquidation. Curve ecosystem only — no Uniswap or other AMMs. |
| **Oryn Finance** | V3 only | CDP model, stablecoin minting. Hackathon-stage project. |

### Indirect / Potential Competitors

| Protocol | Threat | Assessment |
|---|---|---|
| **Morpho Blue / Euler V2 / Silo** | Anyone could create LP collateral markets | Blocked by oracle complexity and liquidation flow (see above) |
| **Fluid (Instadapp)** | High-LTV vaults, DEX+lending combo | Generalist platform, not LP-specific. Could add LP support. |
| **Aave (GHO facilitator)** | Proposal to accept V3 NFTs as collateral | Never implemented. Confirms demand but not execution. |

### Aurelia's Differentiator

The gap in the market is not "lending against LP" — Impermax and Revert already do this. The gap is doing it **cross-AMM with a manipulation-resistant oracle for each curve type.**

The existing competitors validate the demand but also reveal the core challenge:
- **Impermax** built a mathematically elegant oracle for V2 constant-product AMMs that has never been exploited. But when they extended it to V3 concentrated liquidity, the same math broke — resulting in $680K in exploits. Each AMM type has fundamentally different invariants, and reusing one pricing model across all of them fails.
- **Revert's Aerodrome exploit** ($50K) shows the risk of adding new AMM types without a clean adapter architecture — a single vulnerability in the integration layer can drain the protocol.
- **Both have very low TVL** (~$86K real for Impermax, ~$7.4M for Revert) despite being live for years — the market exists but nobody has captured it at scale. Impermax V3 is effectively dead post-exploits.

Aurelia's architecture is designed to avoid these failure modes:

| Problem | Impermax/Revert Approach | Aurelia Approach |
|---|---|---|
| **Oracle** | Single source (AMM TWAP or Chainlink) | Dual oracle per AMM type (TWAP + Chainlink) with 5-layer validation and circuit breakers |
| **New AMM types** | Monolithic integration (risk: Revert's Aerodrome exploit) | Clean adapter/oracle separation — deploy 1 adapter + 1 oracle, zero core changes |
| **Liquidation** | LP tokens to liquidator (Impermax) or flash-loan-based (Revert) | Atomic unwind inside contract — liquidators only deal in stablecoins |
| **AMM math** | Per-pair pricing, single method | Type-specific pricing behind unified `getPrice()` interface: sqrt(k) for V2, TWAP+ticks for V3, virtual price for Curve |

This is the hard infrastructure layer — whoever builds the most accurate LP pricing system wins, because every lending protocol will eventually want to support LP collateral.

---

## 5. Protocol Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     AURELIA PROTOCOL                          │
│                                                                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │
│  │PositionManager│  │ LendingEngine│  │ Liquidation  │        │
│  │              │  │              │  │ Engine       │        │
│  │ Deposit/     │  │ Borrow/Repay │  │ Atomic       │        │
│  │ Withdraw LP  │  │ Interest     │  │ Seize+Unwind │        │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘        │
│         │                 │                  │                 │
│  ┌──────▼─────────────────▼──────────────────▼──────────┐     │
│  │                  ProtocolCore                         │     │
│  │         (Registry, Access Control, Pause)             │     │
│  └────────────────────────┬──────────────────────────────┘     │
│                           │                                    │
│  ┌────────────────────────▼──────────────────────────────┐     │
│  │                   DEX Adapters                         │     │
│  │  UniV3 │ UniV2 │ Curve │ Aerodrome │ PancakeSwap      │     │
│  └────────────────────────────────────────────────────────┘     │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐     │
│  │               Oracle System                            │     │
│  │  LPOracleHub → V3Oracle │ V2Oracle │ CurveOracle │ ...│     │
│  │  + PriceValidator (circuit breakers)                   │     │
│  └────────────────────────────────────────────────────────┘     │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐     │
│  │               Markets (Isolated Lending Pools)         │     │
│  │  Market │ MarketFactory │ InterestRateModel             │     │
│  └────────────────────────────────────────────────────────┘     │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐     │
│  │               Security                                 │     │
│  │  CircuitBreaker │ RiskManager │ PoolHealthMonitor       │     │
│  │  TimelockController (OZ) │ FeeCollector                 │     │
│  └────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────┘
```

### Core Contracts

**ProtocolCore** — Central registry and access control hub. Stores adapter/oracle/market registrations, pool whitelist, and role management (owner, guardian, keepers). Not proxied — it is the root of trust. Two-step ownership transfer for safety.

**PositionManager** (UUPS Proxy) — Manages LP position lifecycle. Accepts deposits from any supported DEX via adapters, tracks position state (Active → Borrowed → Closed/Liquidated), records deposit block for borrow cooldown enforcement.

**LendingEngine** (UUPS Proxy) — Handles borrowing and repayment. Reads interest from Market's cumulative `borrowIndex` (single source of truth — no duplicate tracking). Enforces borrow cooldown, LTV limits, and borrow caps. Per-position debt calculated as `principal × currentBorrowIndex / positionBorrowIndex`.

**LiquidationEngine** (UUPS Proxy) — Atomic liquidation flow: accrue interest → verify health factor → cap to maxLiquidationPortion (50% default, 100% when HF < 0.95) → pull repayment from liquidator → unwind LP via adapter → slippage check (minAmount0/minAmount1) → take protocol fee from bonus portion → send raw underlying tokens to liquidator → repay debt → reduce position / mark liquidated → bad debt writeoff if needed. No swap — liquidators receive the underlying tokens directly.

**Market** (UUPS Proxy) — Isolated lending pool per LP type. Lenders supply stablecoins and receive ERC-4626 style shares. Interest accrued via configurable kinked rate model. Single source of truth for `borrowIndex` — eliminates dual-tracking divergence. Dead shares minted on first deposit to prevent share inflation attacks.

**FeeCollector** — Aave-style reserve factor model. Collects protocol fees via `collectFee()` (pulls tokens, not just ledger updates). Distributes to treasury (90%) and insurance fund (10%).

---

## 6. Oracle System — The Core Moat

The oracle is both the most security-critical component and the primary technical moat. If LP prices can be manipulated, attackers drain the protocol. If LP prices are inaccurate, the protocol either over-lends (bad debt) or under-lends (poor UX). Getting this right across multiple AMM types is the hard problem that competitors have not solved.

No single pricing method works for all AMMs. Each requires a purpose-built oracle that understands the specific invariant curve, then a unified validation layer on top.

### Per-LP-Type Pricing

| LP Type | Method | Key Defense |
|---|---|---|
| Uniswap V3 (NFT) | TWAP tick + Chainlink token prices | 30-min TWAP immune to flash loans |
| Uniswap V2 (ERC-20) | sqrt(k) fair pricing + Chainlink | k stays constant during flash loan |
| Curve (stable pools) | Virtual price + Chainlink | Virtual price only increases (decrease = exploit) |
| Aerodrome | V2-style or V3-style per pool type | Pending emissions excluded from value |

**Uniswap V2 — sqrt(k) Method:**
```
fairValue = 2 × sqrt(k × price0 × price1) / totalSupply
```
Uses Chainlink prices (not pool reserves ratio), making it immune to reserve manipulation.

**Uniswap V3 — TWAP + Chainlink:**
1. Read position params from NFT (tickLower, tickUpper, liquidity)
2. Get 30-minute TWAP tick from pool (manipulation-resistant)
3. Calculate token amounts at TWAP tick
4. Price tokens via Chainlink feeds
5. Cross-validate: TWAP vs Chainlink must agree within 3%

### 5-Layer Defense (PriceValidator)

| Layer | Check | Action on Failure |
|---|---|---|
| 1 | TWAP vs Chainlink deviation > 3% | Circuit breaker — halt pool |
| 2 | Pool TVL below $1M minimum | Circuit breaker — halt pool |
| 3 | TVL dropped > 30% in 1 hour | Circuit breaker — halt pool |
| 4 | Price volatility > 10% in 5 minutes | +5% haircut (don't halt) |
| 5 | Price older than 1 hour | +2% haircut |

All thresholds are configurable by the DAO with absolute safety bounds.

---

## 7. Liquidation Mechanism

When a position's health factor drops below 1.0, anyone can liquidate it:

```
Health Factor = (collateralValue × liquidationThreshold) / (debt × 10000)
HF < 1.0 → liquidatable
HF < 0.95 → critically underwater → 100% liquidation allowed
```

### Partial Liquidation Cap (Aave V3 Pattern)

Not every liquidation should wipe the entire position. A partial cap gives borrowers a chance to recover after a moderate price drop, while still allowing full liquidation for critically underwater positions.

| Health Factor | Max Liquidation | Rationale |
|---|---|---|
| 0.95 ≤ HF < 1.0 | 50% of debt | Partial liquidation — borrower can repay or add collateral to recover |
| HF < 0.95 | 100% of debt | Full liquidation — position is critically underwater, bad debt risk |

The 50% default (`maxLiquidationPortion`) is configurable by POOL_ADMIN within 10-100% bounds. This matches Aave V3's `DEFAULT_LIQUIDATION_CLOSE_FACTOR` / `MAX_LIQUIDATION_CLOSE_FACTOR` design exactly.

### Atomic Liquidation Flow

1. **Accrue interest** — ensure health factor uses latest debt
2. **Verify** — position HF < 1.0
3. **Pull repayment** from liquidator (borrow asset, e.g., USDC)
4. **Repay debt** — full repayAmount goes to LendingEngine (no deduction)
5. **Calculate** proportional liquidity to remove (normalized to 18 decimals for cross-decimal-token safety)
6. **Unwind LP** — adapter calls DEX to remove liquidity → receives underlying tokens (e.g., ETH + USDC)
7. **Update position amount** — reduce stored amount to reflect removed liquidity
8. **Take protocol fee** — % of the bonus portion, deducted proportionally from both underlying tokens (Aave pattern). Fee goes to FeeCollector → treasury + insurance.
9. **Send remaining tokens** directly to liquidator (ETH + USDC minus fee)
10. **Return remaining LP** to borrower (if fully liquidated with surplus)
11. **Mark liquidated** — update position status

### No Swap in Liquidation

The protocol does NOT swap tokens during liquidation. The liquidator receives the raw underlying tokens (e.g., ETH + USDC) directly from the LP unwind. This eliminates swap slippage, MEV sandwich attacks, and SwapRouter dependency from the critical liquidation path.

**Why?** Every LP lending protocol that swaps during liquidation passes `minAmountOut = 0` and relies on a post-swap check (including Revert Lend, audited by Code4rena). This is a known weak pattern — sandwich bots extract value up to the slippage tolerance, and if the swap fails (low liquidity, router bug), the entire liquidation fails, causing bad debt. By removing the swap, liquidations cannot fail due to market conditions.

### V3 Fee-Only Liquidation (Zero Liquidity)

A Uniswap V3 position can end up with zero liquidity (fully unwound by prior partial liquidations) but still hold uncollected trading fees and outstanding debt. The protocol handles this edge case explicitly:

1. LiquidationEngine detects `totalLiquidity == 0 && pos.tokenId > 0` (V3 NFT with no liquidity)
2. Adapter calls `collectFees()` on the NFT — no `decreaseLiquidity` needed
3. Proportional seizure of collected fees based on debt ratio (if fees < total debt)
4. Protocol fee deducted from the seized amount
5. Remaining fees sent to liquidator
6. Debt repaid, or written off as bad debt if fees are insufficient

This ensures no position can avoid liquidation by having its liquidity removed through prior partial liquidations while leaving fees uncollected. The fees still have value and can be seized to cover (or partially cover) the remaining debt.

### Protocol Fee on Liquidation (Aave Pattern)

The protocol takes a fee from the **bonus portion** of the seized collateral, not from the repayment amount. This ensures:
- Full repayAmount goes to debt repayment (no mismatch with maxRepay)
- Full debt clearance always works
- Fee is proportional to the liquidator's profit, not the debt size

```
Example: 5% liquidation bonus, 10% protocol fee on bonus

Liquidator repays:     $16,625 USDC (100% goes to debt)
Collateral unwound:    2.5 ETH + $10,000 USDC (= $17,456 total, includes 5% bonus)
Bonus portion:         $831 (5% of $16,625)
Protocol fee:          $83 (10% of bonus), deducted proportionally from ETH + USDC
Liquidator receives:   remaining ETH + USDC (~$17,373)
FeeCollector receives: proportional ETH + USDC (~$83)
```

The fee is deducted proportionally from both tokens so no swap is needed. FeeCollector accumulates fees in any token — `distribute()` sends them to treasury + insurance.

### FlashloanLiquidator (Optional Helper — Planned)

For liquidation bots that want single-asset simplicity, the protocol will provide an optional `FlashloanLiquidator` periphery contract (inspired by Revert Lend's audited design):

```
1. Bot calls FlashloanLiquidator.liquidate()
2. Flash loan borrow asset (USDC) from Uniswap
3. Call LiquidationEngine.liquidate() → repay debt → receive ETH + USDC
4. Swap ETH → USDC via DEX (bot's choice of route/slippage)
5. Repay flash loan
6. Keep profit
```

The swap happens in the helper contract, not in the core protocol. If the helper has a bug or gets sandwiched, the protocol is unaffected — the debt was already repaid in step 3. The helper is a stateless periphery contract that can be redeployed anytime without affecting the core.

### Avoiding Liquidation

When a position's health factor drops near 1.0, borrowers have two options:

**Option 1: Repay debt.** Call `LendingEngine.repay(positionId, amount)` to reduce outstanding debt. This directly improves the health factor. Partial repayment is supported.

**Option 2: Add collateral.** Call `PositionManager.addCollateral(positionId, amount0, amount1)` to increase the collateral backing an existing position. The user sends the underlying tokens (e.g., WETH + USDC) — the protocol handles the DEX interaction internally. The user never needs to interact with the DEX directly.

Unified interface across all LP types:
```
PositionManager.addCollateral(positionId, amount0, amount1)
```

How it works per LP type:
- **Uniswap V2:** Adapter calls `v2Router.addLiquidity(token0, token1, amount0, amount1)` → receives new LP tokens → `pos.amount` increases. V2 fees continue auto-compounding.
- **Uniswap V3:** Adapter calls `nftManager.increaseLiquidity(tokenId, amount0, amount1)` → NFT's liquidity grows in the same tick range. Uncollected fees are unaffected.
- **Curve / Aerodrome:** Same pattern via their respective deposit functions.

Any tokens not used by the DEX (dust from price ratio mismatch) are refunded to the user.

Example flow:
1. User deposited an LP position worth $50K, borrowed $30K
2. ETH crashes, LP value drops to $38K, HF = 0.95 (critically underwater)
3. User calls `addCollateral(positionId, 3 ETH, 5000 USDC)`
4. Adapter adds liquidity to the same pool → collateral value increases
5. Oracle prices the larger position → HF improves above 1.0

The user stays in the protocol the entire time — no need to visit Uniswap, mint LP tokens, or manage NFTs separately. One call, health factor restored.

### Auto-Compound (V3 Positions)

Uniswap V3 positions accumulate trading fees as uncollected `tokensOwed`. Unlike V2 (where fees auto-compound into reserves), V3 fees sit idle until explicitly collected and reinvested.

The LPCompounder contract auto-compounds these fees permissionlessly:

```
Anyone calls LPCompounder.compoundPosition(positionId)
    → Collect trading fees from V3 NFT
    → 2% protocol fee (FeeCollector) + 0.5% caller reward
    → 97.5% reinvested as additional liquidity via increaseLiquidity()
    → Dust refunded to position owner
```

**Permissionless:** Anyone can compound any position. No need for the position owner to act — MEV bots and keeper networks will compound profitable positions automatically.

**Fee split (configurable by RISK_ADMIN):**
- 2% → protocol (FeeCollector → treasury + insurance)
- 0.5% → caller (reward for paying gas)
- 97.5% → reinvested as liquidity

**Batch compounding:** `batchCompound([positionIds])` compounds multiple positions in one transaction. Failures are silently skipped — one bad position doesn't block others.

---

## 8. Risk Framework

### Risk Parameters Per LP Type

| LP Type | Max LTV | Liq. Threshold | Liq. Bonus | Oracle Haircut | Min Pool TVL |
|---|---|---|---|---|---|
| Curve stable (3pool) | 85% | 90% | 3% | 3% | $10M |
| Uniswap V2 (major) | 70% | 80% | 5% | 5% | $5M |
| Uniswap V3 (wide range) | 65% | 75% | 5% | 7% | $5M |
| Uniswap V3 (narrow range) | 55% | 65% | 7% | 10% | $5M |
| Aerodrome | 60% | 70% | 6% | 8% | $3M |
| PancakeSwap V2/V3 | 60-65% | 70-75% | 5-6% | 7-8% | $3M |
| Exotic pairs (memecoins) | 40% | 50% | 10% | 15% | $1M |

*Hard cap: 15% maximum liquidation bonus enforced in code (`MAX_LIQUIDATION_BONUS = 1500 bps`), aligned with Aave V3's upper bound. Governance cannot set bonus above this limit.*

### Safety Mechanisms

- **Borrow cooldown:** 1+ blocks between deposit and borrow (prevents flash loan attacks)
- **Borrow cap:** Per-market maximum total borrows (configurable by DAO)
- **Position size limit:** $10M max single position
- **Global borrow cap:** Protocol-wide exposure limit
- **Critical liquidation:** Full liquidation allowed when HF < 0.95 (prevents bad debt accumulation)
- **Circuit breakers:** Per-market and per-pool pause on oracle anomalies
- **Interest rate cap:** Absolute ceiling of ~500% APR — governance misconfiguration cannot cause absurd accrual
- **Token constraints:** Borrow assets MUST be standard ERC20 tokens (USDC, USDT, DAI, WETH). Fee-on-transfer, rebasing, and ERC-777 tokens are NOT supported as borrow assets. The LiquidationEngine enforces exact-balance checks on repayment — fee-on-transfer tokens would block all liquidations in that market, creating guaranteed bad debt. This is validated off-chain during market creation and enforced at runtime.

### Bad Debt Management (Aave V3.3 Pattern)

When collateral crashes to $0, liquidation may not recover the full debt. Previous LP lending protocols (Impermax, Revert) had no mechanism for this — bad debt stayed on the books accruing phantom interest forever.

Aurelia handles bad debt automatically:

1. **During liquidation:** If collateral is fully consumed but debt remains, the remaining debt is **burned** from `totalBorrow` and recorded as `deficit` on the market.
2. **Deficit coverage:** `protocolReserves` (the protocol's accumulated interest share) are used to cover the deficit. `RISK_ADMIN` triggers `eliminateDeficit()` to apply reserves against accumulated bad debt.
3. **Isolation:** Each market tracks its own deficit independently. Bad debt in one market does not affect others (same isolation as Morpho Blue).

```
Underwater position → liquidation → collateral = 0, debt remains
                                          ↓
                              LendingEngine.writeOffDebt()
                                          ↓
                     Market.recordDeficit() — burns debt, tracks deficit
                                          ↓
                     Market.eliminateDeficit() — covers with protocolReserves
```

### Frozen Market State (Aave V3 Pattern)

A full protocol pause blocks liquidations — bad debt accumulates during the pause. For targeted incidents (token depeg, oracle issue, exploit), the protocol supports a **frozen** state:

| State | Deposits | Borrows | Withdrawals | Repayments | Liquidations |
|---|---|---|---|---|---|
| **Normal** | Allowed | Allowed | Allowed | Allowed | Allowed |
| **Frozen** | Blocked | Blocked | Allowed | Allowed | Allowed |
| **Paused** | Blocked | Blocked | Blocked | Blocked | Blocked |

- **Who can freeze:** EMERGENCY_ADMIN, KEEPER, or POOL_ADMIN (instant — no timelock)
- **Who can unfreeze:** POOL_ADMIN only (through 48h timelock — prevents premature unfreeze after exploit)
- **Use cases:** USDC depeg, Chainlink feed stale, pool exploit detected

This mirrors Aave V3's "frozen reserve" mechanism, which was used during the March 2023 USDC depeg and the April 2026 Kelp exploit.

---

## 9. Fee Model

Inspired by Aave's revenue model ($907M in total fees in 2025, ~$140M protocol-retained).

### Revenue Sources

| Source | Rate | How It Works |
|---|---|---|
| Reserve factor | 10-25% of interest | Protocol keeps this % of borrow interest. Rest goes to lenders. Per LP type — higher risk = higher cut. |
| Liquidation fee | 10% of liq. penalty | Protocol takes 10% of the liquidation bonus. Liquidators keep 90%. |
| Management fee | 0.1% annual | Annual fee on deposited LP collateral value. Charged by keeper via periodic accrual. Configurable by RISK_ADMIN (max 1%). |
| Compound fee | 2.5% of compounded fees | When V3 trading fees are auto-compounded, protocol keeps 2% and 0.5% goes to the caller as gas reward. Permissionless — anyone can trigger. |

### Reserve Factors by LP Type

| LP Type | Reserve Factor | Rationale |
|---|---|---|
| Curve | 10% | Lowest risk — stable pools, minimal IL |
| UniswapV2/V3 | 20% | Moderate risk |
| Aerodrome | 25% | Higher risk — newer protocol |
| PancakeSwap V2/V3 | 20-25% | Moderate-high risk |

### Fee Distribution

```
Collected fees → FeeCollector
                      │
              ┌───────┴───────┐
              │               │
         90% Treasury    10% Insurance Fund
         (operations,    (bad debt coverage)
          buybacks)
```

All fee rates and distribution ratios are configurable by the DAO with absolute safety bounds.

### Revenue Projections

**Assumptions:** 40% average utilization, 8% weighted average borrow APR, 20% average reserve factor, liquidation events generating ~5% of interest revenue in fees.

```
Revenue = TVL × Utilization × Borrow APR × Reserve Factor + Liquidation Fees

Example at $500M TVL:
  $500M × 40% utilization = $200M total borrows
  $200M × 8% APR = $16M annual interest
  $16M × 20% reserve factor = $3.2M protocol interest revenue
  + ~$160K liquidation fees (est.)
  ≈ $3.4M annual protocol revenue
```

| TVL | Borrows (40% util.) | Interest (8% APR) | Protocol Rev (20% RF) | + Liq. Fees | Total |
|---|---|---|---|---|---|
| $500M | $200M | $16M | $3.2M | ~$0.2M | **~$3.4M** |
| $1B | $400M | $32M | $6.4M | ~$0.3M | **~$6.7M** |
| $2B | $800M | $64M | $12.8M | ~$0.6M | **~$13.4M** |
| $5B | $2B | $160M | $32M | ~$1.5M | **~$33.5M** |

*These are estimates. Actual revenue depends on utilization rates, borrow demand, and market conditions.*

---

## 10. Governance & Token

### Governance Model

The protocol is governed by a DAO with token voting. No centralized team control.

**Phase 1 — Launch:**
- **Team multisig** (3/5) controls the protocol during initial deployment and auditing
- **Guardian:** Separate security multisig (can pause, cannot unpause)
- Goal: ship fast, fix bugs, prove the protocol works

**Phase 2 — DAO Transition:**
- Governance token launched
- **DAO with token voting** replaces team multisig as protocol owner
- Community proposes → vote (5-7 days) → OZ `TimelockController` (48h delay) → execute
- Guardian becomes elected Security Council
- Structural changes (adapter registration, pool whitelisting, role grants) go through the 48h timelock
- Risk parameter changes (LTV, haircut, borrow caps) remain instant via RISK_ADMIN — no timelock needed

### Direction-Based Security

| Direction | Timelock | Examples |
|---|---|---|
| Safer (reduces risk) | None | Lower LTV, increase haircut, pause market |
| Riskier (increases risk) | 24-48h | Raise LTV, new adapter, change fees |
| Emergency | None | Pause protocol (guardian only) |

### Two-Step Ownership Transfer
Ownership transfer requires propose + accept. Prevents accidental loss of protocol control.

### Governance Token

The governance token exists for one purpose: **vote on protocol decisions.** It is not a speculation instrument.

**Distribution:**

| Allocation | Share | Vesting | Purpose |
|---|---|---|---|
| DAO Treasury | 35% | None (DAO controlled) | Fund development, grants, operations, insurance |
| Protocol Usage Rewards | 35% | Emitted over 4 years | Users earn tokens by depositing LP, supplying liquidity, or borrowing |
| Early User Airdrop | 10% | None | Reward users who used the protocol before the token launch |
| Core Contributors | 10% | 4 year vest, 1 year cliff | Team and early builders |
| Strategic Partners & Ecosystem | 10% | 2 year vest, 6 month cliff | Integrations, audit partners, security researchers, launch partners |

**How users earn tokens:**
- **LP depositors** — earn tokens proportional to time × collateral value
- **Lenders** — earn tokens proportional to time × supply amount
- **Borrowers** — earn tokens proportional to time × borrow amount
- Emissions decrease over 4 years following a decay curve

**Fair launch principles:**
- No public sale / IDO / ICO
- No marketing-driven airdrops
- Strategic partners allocation reserved for ecosystem contributors who add technical or distribution value (audit firms, integration partners, security researchers)

**Token utility:**
- Vote on governance proposals (risk parameters, fees, new markets, upgrades)
- Stake in Safety Module to earn protocol revenue share
- Stakers accept slashing risk in exchange for yield (like Aave Umbrella)

**Design principle:** The token has value because the protocol generates real revenue (reserve factor + liquidation fees). Token holders govern that revenue. No Ponzi mechanics, no emissions-driven yield — real fees from real usage.

---

## 11. Smart Contract Security

### UUPS Proxy Pattern

5 core contracts use UUPS upgradeable proxies:
- PositionManager, LendingEngine, LiquidationEngine, LPOracleHub, Market

Non-proxied contracts (deploy new + register):
- ProtocolCore, Adapters, Oracles, InterestRateModel, Periphery, Security modules

### Storage Safety
All proxied contracts include a `uint256[N] private __gap` storage gap for future upgrades without storage collision. Each contract starts with 50 reserved slots; the gap shrinks as new state variables are appended (e.g., PositionManager added 4 vars → gap reduced from 50 to 46). The sum of new vars + gap always equals the original 50.

### Reentrancy Protection
`ReentrancyGuardTransient` on all contracts that make external calls:
- PositionManager (adapters, oracles)
- LendingEngine (market transfers)
- LiquidationEngine (adapters, swaps, fee collection)
- Market (ERC20 transfers in supply/withdraw)

### Additional Protections
- Zero-address validation on all inputs
- Events on every state change (full transparency)
- Absolute bounds on all configurable parameters (can't be exceeded even by DAO)
- CEI pattern (checks-effects-interactions) throughout
- Bad debt auto-writeoff during liquidation (deficit tracking — see Section 8)
- Frozen market state for surgical incident response (see Section 8)
- Interest rate hard cap (~500% APR) — prevents accrual bombs from governance misconfiguration
- USDT-compatible ERC20 approvals (approve(0) before approve(amount))
- Rescue function for stuck tokens in LiquidationEngine

---

## 12. Multi-Chain Strategy

Each chain deployment is independent with shared governance via cross-chain messaging.

| Phase | Chains | AMM Types | Timeline | Target |
|---|---|---|---|---|
| Phase 1 | Ethereum + Base | UniV3, UniV2, Curve, Aerodrome | Months 1-4 | $20-50M TVL |
| Phase 2 | Arbitrum + BSC | + Camelot, PancakeSwap V2/V3 | Months 4-8 | $50-100M TVL |
| Phase 3 | Polygon + others | + QuickSwap, Balancer | Months 8-12 | $100-200M TVL |

**Per chain:** Full protocol deployment (ProtocolCore, PositionManager, LendingEngine, Markets, Oracles) with chain-specific adapters. Adding a new DEX requires deploying one adapter + one oracle — zero changes to core contracts.

---

## 13. Market Opportunity

**Total Addressable Market (TAM):** ~$8B in LP capital across DeFi (DefiLlama, July 2026)

**Serviceable Addressable Market (SAM):** ~$5B — pools meeting minimum TVL ($1M+), minimum age (30+ days), and supported DEX types. Excludes exotic/low-liquidity pairs, pools on unsupported chains, and LP holders who don't want leverage.

**Realistic capture (Year 1-2):** $400M - $1.5B in collateral deposits (5-20% of SAM). Not all LPs want to borrow — our users are DeFi-native LPs seeking capital efficiency, yield farmers seeking leverage, and DAOs seeking to put treasury LP positions to work.

| Scenario | Collateral TVL | Annual Revenue |
|---|---|---|
| Conservative (5% SAM) | $250M | ~$1.7M |
| Base case (10% SAM) | $500M | ~$3.4M |
| Optimistic (20% SAM) | $1B | ~$6.7M |
| Bull case (30% SAM) | $1.5B | ~$10M |

**Comparable protocols:**
- Aave: ~$14.5B TVL (lending leader)
- Morpho: ~$7.2B TVL (modular lending, growing fast)
- Euler V2: ~$890M TVL (permissionless vaults)
- A $500M+ LP lending protocol would rank among the top 30 DeFi protocols by TVL

The protocol's moat is technical: the LP oracle and atomic liquidation engine. Whoever builds the most accurate, manipulation-resistant LP pricing system wins — because every lending protocol will eventually want to support LP collateral.

---

## 14. Roadmap

```
Phase 1 (Months 1-4): Cross-AMM Launch
  ├── Smart contracts finalized + audited
  ├── Ethereum deployment with 3 AMM types from day 1:
  │     UniV3 + UniV2 + Curve (proves cross-AMM oracle)
  ├── Base deployment (Aerodrome — 4th AMM type)
  ├── Liquidation bot + health monitor
  └── Frontend MVP
  → Goal: ship the cross-AMM differentiator on day 1, not incrementally

Phase 2 (Months 4-8): Chain Expansion + Depth
  ├── Arbitrum deployment (Camelot, UniV3, Curve)
  ├── BSC deployment (PancakeSwap V2/V3 — 5th/6th AMM type)
  ├── Additional oracle types (Balancer weighted pools, Velodrome CL)
  └── Institutional API + SDK for liquidation bots

Phase 3 (Months 8-12): Growth + Governance
  ├── Polygon (QuickSwap, UniV3)
  ├── Governance token launch
  ├── Protocol revenue → buybacks
  └── DAO transition

Phase 4 (Month 12+): Decentralization
  ├── Token voting governance
  ├── Elected Security Council
  ├── Cross-chain governance
  └── Optional: protocol lock (disable upgrades forever)
```

**Rationale:** If our moat is the cross-AMM oracle, we must prove it at launch — not ship as single-DEX and promise more later. Phase 1 deploys on Ethereum (UniV3 + V2 + Curve) and Base (Aerodrome) simultaneously, covering 4 AMM types across 2 chains from day 1. This immediately differentiates from Impermax (single-pair markets), Revert (V3-only), and Curve Lend (Curve-only).

---

## 15. References

### Protocols
- **Aave V3/V4** — Lending architecture, reserve factor model, risk premiums. $907M total fees 2025 (KuCoin, CryptoBriefing).
- **Morpho** — Modular isolated markets, permissionless vault design. ~$7.2B TVL (DefiLlama).
- **Euler V2** — Permissionless lending vaults. ~$890M TVL. V1 exploited for $197M on March 13, 2023 (Bloomberg).
- **Lido** — Liquid staking model, ~$15B TVL (DefiLlama). Inspiration for "liquid LP" concept.
- **Pendle** — Yield tokenization (PT/YT split)

### Competitors
- **Impermax** — Multi-chain LP collateral lending. Permissionless isolated markets per pair. Supports V2, V3, and various AMMs via NFTLP generalization.
- **Revert Lend** — Uniswap V3 NFT position lending with continuous health monitoring. Single DEX.
- **YLDR** — Aave fork for leveraged V3 LP positions. LTV up to 70%+. Single DEX.
- **Curve Lend (llamalend)** — Native Curve LP lending using LLAMMA soft-liquidation mechanism. Curve ecosystem only.
- **Fluid (Instadapp)** — High-LTV vault architecture with DEX+lending modules. Generalist platform.
- **Silo Finance** — Isolated lending markets with customizable risk parameters.

### Standards & Infrastructure
- **ERC-4626** — Tokenized vault standard (EIP-4626, finalized March 2022)
- **OpenZeppelin** — UUPS proxy (EIP-1822), ReentrancyGuard, Initializable
- **Chainlink** — Price feeds for cross-validation
- **Alpha Finance** — sqrt(k) fair LP pricing method

### Data Sources
- **DefiLlama** — TVL data for all protocols and DEXes (defillama.com)
- **Aave Revenue** — KuCoin Flash News, CryptoBriefing (confirmed $907M total fees 2025)
- **Euler Hack** — Bloomberg, March 13, 2023 ($197M, later returned)
- **stETH Depeg** — TrustNodes, June 13, 2022 (dropped to 0.93 ETH)
- **Aavenomics 3.0** — The Defiant, June 2026 (automated buybacks replacing $30M/yr committee model)

---

*Aurelia — Unlocking the $8B LP economy. [aurelia.finance](https://aurelia.finance)*
