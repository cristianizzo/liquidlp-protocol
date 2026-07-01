import { logger } from '../../shared/logger';

export interface LiquidatablePosition {
  id: bigint;
  healthFactor: bigint;
  debt: bigint;
  maxRepay: bigint;
  chain: string;
}

export const scanner = {
  async findLiquidatablePositions(): Promise<LiquidatablePosition[]> {
    // TODO: For each supported chain:
    // 1. Call PositionViewer.getUserPositions() for tracked users
    //    OR use subgraph to get all positions with debt
    // 2. Filter positions where healthFactor < 1e18
    // 3. Call LiquidationEngine.isLiquidatable() to verify on-chain
    // 4. Return verified liquidatable positions

    logger.debug('Scanning for liquidatable positions...');
    return [];
  },
};
