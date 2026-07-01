import { LPType } from '../types/position';

export interface RiskParams {
  maxLtvBps: number;
  liquidationThresholdBps: number;
  liquidationBonusBps: number;
  haircutBps: number;
  minPoolTvlUsd: number;
  minPoolAgeDays: number;
}

export const riskParams: Record<LPType, RiskParams> = {
  [LPType.UniswapV2]: {
    maxLtvBps: 7000,
    liquidationThresholdBps: 8000,
    liquidationBonusBps: 500,
    haircutBps: 500,
    minPoolTvlUsd: 5_000_000,
    minPoolAgeDays: 30,
  },
  [LPType.UniswapV3]: {
    maxLtvBps: 6500,
    liquidationThresholdBps: 7500,
    liquidationBonusBps: 500,
    haircutBps: 700,
    minPoolTvlUsd: 5_000_000,
    minPoolAgeDays: 30,
  },
  [LPType.Curve]: {
    maxLtvBps: 8500,
    liquidationThresholdBps: 9000,
    liquidationBonusBps: 300,
    haircutBps: 300,
    minPoolTvlUsd: 10_000_000,
    minPoolAgeDays: 30,
  },
  [LPType.Aerodrome]: {
    maxLtvBps: 6000,
    liquidationThresholdBps: 7000,
    liquidationBonusBps: 600,
    haircutBps: 800,
    minPoolTvlUsd: 3_000_000,
    minPoolAgeDays: 30,
  },
  [LPType.PancakeSwapV2]: {
    maxLtvBps: 6500,
    liquidationThresholdBps: 7500,
    liquidationBonusBps: 500,
    haircutBps: 700,
    minPoolTvlUsd: 3_000_000,
    minPoolAgeDays: 30,
  },
  [LPType.PancakeSwapV3]: {
    maxLtvBps: 6000,
    liquidationThresholdBps: 7000,
    liquidationBonusBps: 600,
    haircutBps: 800,
    minPoolTvlUsd: 3_000_000,
    minPoolAgeDays: 30,
  },
};
