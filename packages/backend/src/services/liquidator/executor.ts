import { logger } from '../../shared/logger';
import type { LiquidatablePosition } from './scanner';

export interface LiquidationResult {
  txHash: string;
  profit: bigint;
  gasUsed: bigint;
}

export const executor = {
  async liquidate(position: LiquidatablePosition): Promise<LiquidationResult> {
    logger.info({ positionId: position.id }, 'Executing liquidation...');

    // TODO:
    // 1. Simulate liquidation via Tenderly or local node to check profitability
    // 2. Calculate optimal repay amount (maximize profit after gas)
    // 3. Approve borrow asset to LiquidationEngine (if not already)
    // 4. Call LiquidationEngine.liquidate(positionId, repayAmount)
    // 5. Return result

    throw new Error('Not implemented');
  },
};
