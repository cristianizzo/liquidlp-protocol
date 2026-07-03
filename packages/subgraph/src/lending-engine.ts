
import { BigDecimal } from '@graphprotocol/graph-ts';
import { BorrowEvent, RepayEvent } from '../generated/schema';

export function handleBorrowed(/* event: Borrowed */): void {
  // TODO:
  // let borrowEvent = new BorrowEvent(event.transaction.hash.toHex() + '-' + event.logIndex.toString());
  // borrowEvent.position = event.params.positionId.toString();
  // borrowEvent.borrower = event.params.borrower;
  // borrowEvent.amount = event.params.amount.toBigDecimal();
  // borrowEvent.totalDebt = event.params.totalDebt.toBigDecimal();
  // borrowEvent.timestamp = event.block.timestamp;
  // borrowEvent.txHash = event.transaction.hash;
  // borrowEvent.save();
  //
  // Update position's currentDebt
  // let position = Position.load(event.params.positionId.toString());
  // if (position) {
  //   position.currentDebt = event.params.totalDebt.toBigDecimal();
  //   position.status = "borrowed";
  //   position.updatedAt = event.block.timestamp;
  //   position.save();
  // }
}

export function handleRepaid(/* event: Repaid */): void {
  // TODO:
  // let repayEvent = new RepayEvent(event.transaction.hash.toHex() + '-' + event.logIndex.toString());
  // repayEvent.position = event.params.positionId.toString();
  // repayEvent.repayer = event.params.repayer;
  // repayEvent.amount = event.params.amount.toBigDecimal();
  // repayEvent.remainingDebt = event.params.remainingDebt.toBigDecimal();
  // repayEvent.timestamp = event.block.timestamp;
  // repayEvent.txHash = event.transaction.hash;
  // repayEvent.save();
}
