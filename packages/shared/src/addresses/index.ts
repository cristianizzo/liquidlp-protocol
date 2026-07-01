export interface ProtocolAddresses {
  protocolCore: `0x${string}`;
  lpOracleHub: `0x${string}`;
  positionManager: `0x${string}`;
  lendingEngine: `0x${string}`;
  liquidationEngine: `0x${string}`;
  feeCollector: `0x${string}`;
  circuitBreaker: `0x${string}`;
  riskManager: `0x${string}`;
  marketFactory: `0x${string}`;
  marketRegistry: `0x${string}`;
  router: `0x${string}`;
  positionViewer: `0x${string}`;
}

// Placeholder — populated after deployment
export const addresses: Record<number, ProtocolAddresses> = {
  // 1: { ... }      // Ethereum mainnet
  // 8453: { ... }   // Base
  // 42161: { ... }  // Arbitrum
};
