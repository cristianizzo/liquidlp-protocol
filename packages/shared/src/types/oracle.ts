export interface PriceResult {
  totalValue: bigint;
  principalValue: bigint;
  feeValue: bigint;
  haircut: bigint;
  confidence: bigint;
  timestamp: bigint;
}

export enum OracleSource {
  ChainlinkTWAP = 'chainlink_twap',
  UniswapTWAP = 'uniswap_twap',
  CurveVirtualPrice = 'curve_virtual_price',
}
