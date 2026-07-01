export enum LPType {
  UniswapV2 = 0,
  UniswapV3 = 1,
  Curve = 2,
  Aerodrome = 3,
  PancakeSwapV2 = 4,
  PancakeSwapV3 = 5,
}

export enum PositionStatus {
  Active = 0,
  Borrowed = 1,
  Liquidated = 2,
}

export interface Position {
  id: bigint;
  owner: `0x${string}`;
  lpToken: `0x${string}`;
  tokenId: bigint;
  amount: bigint;
  lpType: LPType;
  pool: `0x${string}`;
  token0: `0x${string}`;
  token1: `0x${string}`;
  marketId: bigint;
  status: PositionStatus;
  depositTimestamp: bigint;
}

export interface PositionView {
  id: bigint;
  owner: `0x${string}`;
  lpToken: `0x${string}`;
  tokenId: bigint;
  amount: bigint;
  lpType: LPType;
  status: PositionStatus;
  collateralValue: bigint;
  debt: bigint;
  healthFactor: bigint;
  maxBorrow: bigint;
  availableToBorrow: bigint;
}
