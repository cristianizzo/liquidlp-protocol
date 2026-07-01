export const protocolFees = {
  interestSpreadBps: 30, // 0.3% of interest goes to protocol
  liquidationFeeBps: 100, // 1% of liquidation value
  managementFeeBps: 10, // 0.1% annual on deposits
  insuranceFundShareBps: 1000, // 10% of fees go to insurance fund
} as const;
