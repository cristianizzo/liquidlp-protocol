# TODO: Full Auto-Compound Implementation

## Current State
`LPCompounder.compoundPosition()` collects fees from V3 NFTs but does NOT reinvest them. Collected fees sit in the adapter contract. A `sweepTokens()` function allows PoolAdmin to recover stuck tokens.

## What's Needed

### Step 1: Collect fees ✅ (done)
`adapter.collectFees(pos.lpToken, pos.tokenId)` — collects unclaimed trading fees from the V3 NFT.

### Step 2: Approve tokens to NFT manager
After collection, the tokens are in the adapter. Need to approve them to `nftManager` for `increaseLiquidity`.

### Step 3: Call `adapter.addLiquidity()` to reinvest
`adapter.addLiquidity()` already exists (built in PR #22). It calls `nftManager.increaseLiquidity()` to add tokens back into the same tick range.

```solidity
adapter.addLiquidity(
    pos.lpToken,
    pos.tokenId,
    pos.token0,
    pos.token1,
    fees0,
    fees1,
    pos.owner  // refund dust to position owner
);
```

### Step 4: Handle dust
`increaseLiquidity` may not use all tokens (price ratio mismatch). The `addLiquidity` function already handles this — it refunds unused tokens to `refundTo`.

## Infrastructure Ready
- `ILPAdapter.addLiquidity()` — interface exists
- `UniswapV3Adapter.addLiquidity()` — implementation exists
- `INonfungiblePositionManager.IncreaseLiquidityParams` — interface exists
- `sweepTokens()` — fallback for stuck tokens

## Priority
Low — fees still count toward position value via oracle's `tokensOwed` reading. Auto-compound is a UX improvement, not a security fix.