import { Hono } from 'hono';

export const positionsRouter = new Hono();

// GET /api/positions/:address — Get all positions for a user
positionsRouter.get('/:address', async (c) => {
  const address = c.req.param('address');
  // TODO: Query PositionViewer contract or subgraph
  return c.json({ positions: [], address });
});

// GET /api/positions/:address/:positionId — Get single position detail
positionsRouter.get('/:address/:positionId', async (c) => {
  const { address, positionId } = c.req.param();
  // TODO: Query PositionViewer.getPositionView(positionId)
  return c.json({ position: null, address, positionId });
});
