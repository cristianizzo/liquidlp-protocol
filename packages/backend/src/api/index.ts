import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { logger } from '../shared/logger';
import { config } from '../shared/config';
import { positionsRouter } from './routes/positions';
import { marketsRouter } from './routes/markets';
import { analyticsRouter } from './routes/analytics';
import { healthRouter } from './routes/health';

const app = new Hono();

// Middleware
app.use('*', cors());

// Routes
app.route('/api/positions', positionsRouter);
app.route('/api/markets', marketsRouter);
app.route('/api/analytics', analyticsRouter);
app.route('/api/health', healthRouter);

// Start server
const port = config.port;
logger.info(`LiquidLP API starting on port ${port}`);

export default {
  port,
  fetch: app.fetch,
};
