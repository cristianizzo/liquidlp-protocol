import { LPType } from './position';

export interface MarketConfig {
  lpType: LPType;
  borrowAsset: `0x${string}`;
  maxLtv: bigint;
  liquidationThreshold: bigint;
  liquidationBonus: bigint;
  haircut: bigint;
  borrowCap: bigint;
  minPoolTvl: bigint;
  minPoolAge: bigint;
}

export interface MarketState {
  totalSupply: bigint;
  totalBorrow: bigint;
  supplyRate: bigint;
  borrowRate: bigint;
  utilization: bigint;
  lastAccrualTimestamp: bigint;
}

export interface MarketView {
  id: bigint;
  lpType: LPType;
  borrowAsset: `0x${string}`;
  totalSupply: bigint;
  totalBorrow: bigint;
  utilization: bigint;
  supplyRateAPR: bigint;
  borrowRateAPR: bigint;
  maxLtv: bigint;
}
