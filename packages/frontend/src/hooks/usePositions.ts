'use client';

import { useAccount } from 'wagmi';
import { useQuery } from '@tanstack/react-query';
import type { PositionView } from '@liquidlp/shared';

export function usePositions() {
  const { address } = useAccount();

  return useQuery({
    queryKey: ['positions', address],
    queryFn: async (): Promise<PositionView[]> => {
      if (!address) return [];
      // TODO: Call PositionViewer.getUserPositions(address) via viem
      // or fetch from backend API
      return [];
    },
    enabled: !!address,
    refetchInterval: 15_000, // Refresh every 15 seconds
  });
}
