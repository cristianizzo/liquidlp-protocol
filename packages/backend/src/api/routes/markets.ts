import { Hono } from 'hono';

export const marketsRouter = new Hono();

// GET /api/markets — List all markets
marketsRouter.get('/', async (c) => {
  // TODO: Query MarketRegistry + MarketViewer
  return c.json({ markets: [] });
});

// GET /api/markets/:id — Single market details
marketsRouter.get('/:id', async (c) => {
  const id = c.req.param('id');
  // TODO: Query PositionViewer.getMarketView(id)
  return c.json({ market: null, id });
});
