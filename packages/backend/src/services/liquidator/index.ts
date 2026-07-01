import { logger } from '../../shared/logger';
import { scanner } from './scanner';
import { executor } from './executor';

const SCAN_INTERVAL_MS = 12_000; // ~1 block on Ethereum

async function main() {
  logger.info('LiquidLP Liquidation Bot starting...');

  // Main loop
  setInterval(async () => {
    try {
      // Scan for liquidatable positions
      const liquidatable = await scanner.findLiquidatablePositions();

      if (liquidatable.length === 0) return;

      logger.info(`Found ${liquidatable.length} liquidatable positions`);

      // Execute liquidations
      for (const position of liquidatable) {
        try {
          const result = await executor.liquidate(position);
          logger.info({ positionId: position.id, profit: result.profit }, 'Liquidation executed');
        } catch (err) {
          logger.error({ positionId: position.id, err }, 'Liquidation failed');
        }
      }
    } catch (err) {
      logger.error({ err }, 'Scan cycle failed');
    }
  }, SCAN_INTERVAL_MS);
}

main().catch((err) => {
  logger.fatal({ err }, 'Liquidation bot crashed');
  process.exit(1);
});
