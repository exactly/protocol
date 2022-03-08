import { BigNumber } from "ethers";
import { expect } from "chai";
import { parseUnits } from "ethers/lib/utils";
import assert from "assert";

export interface BorrowFromMaturityPoolEventInterface {
  to: string;
  amount: BigNumber;
  commission: BigNumber;
  maturityDate: BigNumber;
}

export interface DepositToMaturityPoolEventInterface {
  from: string;
  amount: BigNumber;
  commission: BigNumber;
  maturityDate: BigNumber;
}

export function errorUnmatchedPool(
  state: PoolState,
  requiredState: PoolState,
  alternativeState?: PoolState
): string {
  if (alternativeState) {
    return (
      "UnmatchedPoolStateMultiple(" +
      state +
      ", " +
      requiredState +
      ", " +
      alternativeState +
      ")"
    );
  }
  return "UnmatchedPoolState(" + state + ", " + requiredState + ")";
}

export function errorGeneric(errorCode: ProtocolError): string {
  return "GenericError(" + errorCode + ")";
}

// it was impossible to find the type for a transaction populated with events,
// in both ethers and hardhat-ethers
export async function expectFee(tx: any, expectedFee: BigNumber) {
  const { events } = await tx.wait();
  const borrowEvents = events.filter(
    (it: any) => it.event === "BorrowFromMaturityPool"
  );
  assert(
    borrowEvents.length < 2,
    "searched for one event, but many were found"
  );
  assert(
    borrowEvents.length > 0,
    "searched for one event, but none were found"
  );
  const event = borrowEvents[0];
  const lowerBoundary = expectedFee.mul("99").div("100");
  const higherBoundary = expectedFee.mul("101").div("100");
  expect(event.args.fee).to.be.gt(lowerBoundary);
  expect(event.args.fee).to.be.lt(higherBoundary);
}

export function applyMaxFee(amount: BigNumber): BigNumber {
  return amount.add(amount.div(10)); // 10%
}

export function discountMaxFee(amount: BigNumber): BigNumber {
  return amount.sub(amount.div(10)); // 10%
}

export function noDiscount(amount: BigNumber): BigNumber {
  return amount; // 0%
}

export function applyMinFee(amount: BigNumber): BigNumber {
  return amount; // 0%
}

export enum PoolState {
  NONE,
  INVALID,
  MATURED,
  VALID,
  NOT_READY,
}

export enum ProtocolError {
  NO_ERROR,
  MARKET_NOT_LISTED,
  MARKET_ALREADY_LISTED,
  SNAPSHOT_ERROR,
  PRICE_ERROR,
  INSUFFICIENT_LIQUIDITY,
  INSUFFICIENT_SHORTFALL,
  AUDITOR_MISMATCH,
  TOO_MUCH_REPAY,
  REPAY_ZERO,
  TOKENS_MORE_THAN_BALANCE,
  INVALID_POOL_STATE,
  INVALID_POOL_ID,
  LIQUIDATOR_NOT_BORROWER,
  NOT_A_FIXED_LENDER_SENDER,
  INVALID_SET_BORROW_CAP,
  MARKET_BORROW_CAP_REACHED,
  INCONSISTENT_PARAMS_LENGTH,
  REDEEM_CANT_BE_ZERO,
  EXIT_MARKET_BALANCE_OWED,
  CALLER_MUST_BE_FIXED_LENDER,
  CONTRACT_ALREADY_INITIALIZED,
  INSUFFICIENT_PROTOCOL_LIQUIDITY,
  EXCEEDED_MAX_UTILIZATION_RATE,
  TOO_MUCH_SLIPPAGE,
  TOO_MUCH_REPAY_TRANSFER,
  SMART_POOL_FUNDS_LOCKED,
  INVALID_TIME_DIFFERENCE,
  INVALID_SP_FEE_RATE,
  INVALID_AMOUNT,
}

export type EnvConfig = {
  mockedTokens?: Map<string, MockedTokenSpec>;
  useRealInterestRateModel?: boolean;
};

export type MockedTokenSpec = {
  decimals: BigNumber | number;
  collateralRate: BigNumber;
  usdPrice: BigNumber;
};

export type MaturityPoolState = {
  borrowFees: BigNumber;
  earningsTreasury: BigNumber;
  earningsUnassigned: BigNumber;
  earningsSP: BigNumber;
  earningsMP: BigNumber;
  earningsDiscounted: BigNumber;
};

export const defaultMockedTokens: Map<string, MockedTokenSpec> = new Map([
  [
    "DAI",
    {
      decimals: 18,
      collateralRate: parseUnits("0.8"),
      usdPrice: parseUnits("1"),
    },
  ],
  [
    "WETH",
    {
      decimals: 18,
      collateralRate: parseUnits("0.7"),
      usdPrice: parseUnits("3000"),
    },
  ],
  [
    "WBTC",
    {
      decimals: 8,
      collateralRate: parseUnits("0.6"),
      usdPrice: parseUnits("63000"),
    },
  ],
  [
    "USDC",
    {
      decimals: 6,
      collateralRate: parseUnits("0.8"),
      usdPrice: parseUnits("1"),
    },
  ],
]);

export class ExaTime {
  timestamp: number;
  ONE_HOUR: number = 3600;
  ONE_DAY: number = 86400;
  ONE_SECOND: number = 1;
  INTERVAL: number = 86400 * 7;
  MAX_POOLS: number = 12;

  constructor(timestamp: number = Math.floor(Date.now() / 1000)) {
    this.timestamp = timestamp;
  }

  public day(dayNumber: number): number {
    return this.timestamp + this.ONE_DAY * dayNumber;
  }

  public nextPoolID(): number {
    return this.timestamp - (this.timestamp % this.INTERVAL) + this.INTERVAL;
  }

  public poolIDByNumberOfWeek(weekNumber: number): number {
    return (
      this.timestamp -
      (this.timestamp % this.INTERVAL) +
      this.INTERVAL * weekNumber
    );
  }

  public isPoolID(): boolean {
    return this.timestamp % this.INTERVAL == 0;
  }

  public pastPoolID(): number {
    return this.timestamp - (this.timestamp % this.INTERVAL) - this.INTERVAL;
  }

  public invalidPoolID(): number {
    return (
      this.timestamp - (this.timestamp % this.INTERVAL) + this.INTERVAL + 33
    );
  }

  public distantFuturePoolID(): number {
    return this.futurePools().pop()! + 86400 * 7;
  }

  public futurePools(): number[] {
    let nextPoolID = this.nextPoolID();
    var allPools: number[] = [];
    for (let i = 0; i < this.MAX_POOLS; i++) {
      allPools.push(nextPoolID);
      nextPoolID += this.INTERVAL;
    }
    return allPools;
  }
}
