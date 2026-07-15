# Aurelia Protocol — TODO

## Completed

### Critical (C)
- [x] **C-1:** TOCTOU borrow cap bypass — atomic `validateAndRecordBorrow` (PR #36)
- [x] **C-2:** V2 full liquidation status transition — `updateDebt(0)` fix (PR #46)

### Important (I)
- [x] **I-1:** Interfaces completed — IMarket, ILendingEngine, IPositionManager, ILiquidationEngine (PR #45)
- [x] **I-2:** Chainlink consolidated into PriceFeedRegistry (PR #45)
- [x] **I-3:** PriceFeedRegistry + RiskManager moved to ProtocolCore (PR #45)
- [x] **I-4:** compoundFees fee recipient validation (PR #36)
- [x] **I-5:** UniswapV3Oracle constructor zero-address checks (PR #45)
- [x] **I-6:** MarketFactory input validation (PR #38)
- [x] **I-7:** InterestRateModel slope2 >= slope1 (PR #38)
- [x] **I-8:** Math.mulDiv overflow-safe debt calculation (PR #36)
- [x] **I-9:** getDebt short-circuit when principal == 0 (PR #36)
- [x] **I-11:** managementFeeBps deprecated (PR #44)
- [x] **I-12:** LPOracleHub registerOracle event (PR #45)
- [x] **I-14:** RiskManager recordWithdraw drift event (PR #36)
- [x] **I-16:** Unused depositor parameter removed (PR #36)
- [x] **I-17:** DEAD_SHARES increased to 1_000_000 (PR #43)

### Oracle Hardening (in progress)
- [x] V3Oracle: overflow-safe `_normalizeTo18` via mulDiv
- [x] V3Oracle: overflow-safe Chainlink ratio via mulDiv
- [x] V3Oracle: early decimal validation before normalization
- [x] V2Oracle: overflow-safe `_normalizeTo18` via mulDiv
- [x] V2Oracle: lpToken validation (require contract + supported pool)
- [x] V2Oracle: removed unused ACLManager import + onlyPoolAdmin modifier
- [x] V2Oracle: added `test_unsupportedPool_reverts` test

### Features
- [x] FlashloanLiquidator — capital-free liquidations via V3 flash loans (PR #44)
- [x] 70/30 liquidation fee split — protocol 70%, liquidator 30% (PR #44)
- [x] Oracle haircuts removed — real market prices, safety from LTV gap (PR #44)
- [x] Auto-compound V3 fees — permissionless, 2.5% fee (PR #37)
- [x] Real-data E2E tests — 6 tests with fork prices (PR #46)
- [x] CI: Anvil at pinned block, deterministic fork tests (PR #46)

---

## Remaining — Should Fix

### Suggestions from Architecture Review
- [ ] **I-10:** FlashloanLiquidator swaps with `amountOutMinimum: 0` — sandwich risk (mitigated by `minProfit`)
- [ ] **I-13:** PoolHealthMonitor constructor missing zero-address checks
- [ ] **I-15:** CircuitBreaker `isOperationAllowed` doesn't check pool-level pause
- [ ] `_ownerPositions` grows unboundedly — closed/liquidated IDs remain in array
- [ ] `removePool()` has no guard against orphaning active positions
- [ ] `CRITICAL_HF_THRESHOLD` and `DUST_THRESHOLD_USD` are constants — consider making configurable

### Code Quality
- [ ] Extract TickMathLib and LiquidityAmountsLib to separate library files (V3Oracle is 446 lines)
- [ ] Deduplicate IAggregatorV3 interface (defined in PriceFeedRegistry, was in oracles)
- [ ] Add pause mechanism on oracles (if Chainlink compromised)

---

## V1.1 Roadmap

### Periphery Contracts
- [ ] **CompoundSwapRouter** — swap non-borrow tokens during compound for better reinvestment
- [ ] **LeverageTransformer** — one-click leverage (flash loan → deposit → borrow → repay loop)
- [ ] **Open-source liquidation bot** — reference implementation for MEV-protected liquidations

### Protocol Extensions
- [ ] Multi-chain deployment (Base, Arbitrum, BSC)
- [ ] Curve LP support (CurveOracle + CurveAdapter)
- [ ] Aerodrome/Velodrome LP support
- [ ] PancakeSwap V2/V3 support
- [ ] Governance token + DAO (TimelockController + Governor)
