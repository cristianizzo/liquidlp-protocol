import { BigDecimal, BigInt } from '@graphprotocol/graph-ts';
import { Position, ProtocolStats } from '../generated/schema';

// Event handler stubs — implement after codegen

export function handlePositionCreated(/* event: PositionCreated */): void {
  // TODO: Create Position entity
  // let position = new Position(event.params.positionId.toString());
  // position.owner = event.params.owner;
  // position.lpToken = event.params.lpToken;
  // position.tokenId = event.params.tokenId;
  // position.lpType = getLPTypeName(event.params.lpType);
  // position.depositValue = event.params.value.toBigDecimal();
  // position.currentDebt = BigDecimal.zero();
  // position.status = "active";
  // position.depositTimestamp = event.block.timestamp;
  // position.updatedAt = event.block.timestamp;
  // position.save();
  //
  // Update protocol stats
  // let stats = getOrCreateProtocolStats();
  // stats.totalPositions = stats.totalPositions.plus(BigInt.fromI32(1));
  // stats.save();
}

export function handlePositionClosed(/* event: PositionClosed */): void {
  // TODO: Update Position status to "closed"
}

export function handlePositionLiquidated(/* event: PositionLiquidated */): void {
  // TODO: Update Position status to "liquidated"
}

function getOrCreateProtocolStats(): ProtocolStats {
  let stats = ProtocolStats.load('1');
  if (stats == null) {
    stats = new ProtocolStats('1');
    stats.totalTVL = BigDecimal.zero();
    stats.totalBorrowed = BigDecimal.zero();
    stats.totalPositions = BigInt.zero();
    stats.totalLiquidations = BigInt.zero();
    stats.totalFeesCollected = BigDecimal.zero();
  }
  return stats;
}
