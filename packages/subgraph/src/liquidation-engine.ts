import { BigDecimal, BigInt } from '@graphprotocol/graph-ts';
import { LiquidationEvent, ProtocolStats } from '../generated/schema';

export function handleLiquidationExecuted(/* event: LiquidationExecuted */): void {
  // TODO:
  // let liqEvent = new LiquidationEvent(event.transaction.hash.toHex() + '-' + event.logIndex.toString());
  // liqEvent.position = event.params.positionId.toString();
  // liqEvent.liquidator = event.params.liquidator;
  // liqEvent.repayAmount = event.params.repayAmount.toBigDecimal();
  // liqEvent.collateralSeized = event.params.collateralSeized.toBigDecimal();
  // liqEvent.liquidatorProfit = event.params.liquidatorProfit.toBigDecimal();
  // liqEvent.timestamp = event.block.timestamp;
  // liqEvent.txHash = event.transaction.hash;
  // liqEvent.save();
  //
  // Update protocol stats
  // let stats = ProtocolStats.load("1")!;
  // stats.totalLiquidations = stats.totalLiquidations.plus(BigInt.fromI32(1));
  // stats.save();
}
