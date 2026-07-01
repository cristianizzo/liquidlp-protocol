import { createPublicClient, http } from 'viem';
import { mainnet, base, arbitrum, bsc, polygon } from 'viem/chains';
import { config } from './config';

export const clients = {
  ethereum: createPublicClient({
    chain: mainnet,
    transport: http(config.rpc.ethereum),
  }),
  base: createPublicClient({
    chain: base,
    transport: http(config.rpc.base),
  }),
  arbitrum: createPublicClient({
    chain: arbitrum,
    transport: http(config.rpc.arbitrum),
  }),
  bsc: createPublicClient({
    chain: bsc,
    transport: http(config.rpc.bsc),
  }),
  polygon: createPublicClient({
    chain: polygon,
    transport: http(config.rpc.polygon),
  }),
} as const;

export type SupportedChain = keyof typeof clients;
