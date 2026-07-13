# Task: Implement FlashloanLiquidator Periphery Contract

**Priority:** Medium
**Type:** Feature — New Contract
**PR:** Standalone

## Context

The whitepaper (Section 7) describes a `FlashloanLiquidator` periphery contract that enables capital-efficient liquidations via flash loans. This contract is documented but **not yet implemented**.

Revert Lend ships an audited `FlashloanLiquidator` (Code4rena reviewed) — our design is inspired by theirs.

## Specification (from whitepaper)

```
1. Bot calls FlashloanLiquidator.liquidate()
2. Flash loan borrow asset (USDC) from Uniswap
3. Call LiquidationEngine.liquidate() → repay debt → receive ETH + USDC
4. Swap ETH → USDC via DEX (bot's choice of route/slippage)
5. Repay flash loan
6. Keep profit
```

## Requirements

- Stateless periphery contract (no storage, no proxy needed)
- Flash loan from Uniswap V3 pool (or Aave V3 flash loan)
- Caller specifies swap route and slippage params
- Swap happens in the helper, NOT in core protocol
- If helper has a bug or gets sandwiched, core protocol is unaffected (debt already repaid in step 3)
- Can be redeployed without affecting core contracts
- Support both V2 and V3 LP position liquidations

## Implementation Notes

- Reference: Revert Lend's `FlashloanLiquidator.sol` (audited by Code4rena)
- Place in `src/periphery/FlashloanLiquidator.sol`
- Add tests in `test/periphery/FlashloanLiquidator.t.sol`
- Consider using Uniswap V3's `flash()` callback pattern

## Acceptance Criteria

- [ ] Contract compiles and passes `forge build`
- [ ] Unit tests for happy path (flash loan → liquidate → swap → repay → profit)
- [ ] Unit tests for edge cases (swap fails, insufficient profit, reentrancy)
- [ ] Fork test against mainnet Uniswap V3 pool
- [ ] Gas benchmarks
