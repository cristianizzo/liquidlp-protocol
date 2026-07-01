import { Hono } from 'hono';

export const analyticsRouter = new Hono();

// GET /api/analytics/tvl — Protocol TVL across all chains
analyticsRouter.get('/tvl', async (c) => {
  // TODO: Aggregate TVL from all markets on all chains
  return c.json({ totalTvl: '0', byChain: {} });
});

// GET /api/analytics/volume — Liquidation volume, borrow volume
analyticsRouter.get('/volume', async (c) => {
  // TODO: Query from indexed events
  return c.json({ borrowVolume24h: '0', liquidationVolume24h: '0' });
});
