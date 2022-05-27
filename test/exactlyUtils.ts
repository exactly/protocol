import type { ContractTransaction } from "ethers";
import { BigNumber } from "ethers";
import { expect } from "chai";
import { parseUnits } from "ethers/lib/utils";
import assert from "assert";

export interface BorrowAtMaturityEventInterface {
  to: string;
  amount: BigNumber;
  commission: BigNumber;
  maturity: BigNumber;
}

export interface DepositAtMaturityEventInterface {
  from: string;
  amount: BigNumber;
  commission: BigNumber;
  maturity: BigNumber;
}

export function errorUnmatchedPool(state: PoolState, requiredState: PoolState, alternativeState?: PoolState): string {
  if (alternativeState) {
    return "UnmatchedPoolStateMultiple(" + state + ", " + requiredState + ", " + alternativeState + ")";
  }
  return "UnmatchedPoolState(" + state + ", " + requiredState + ")";
}

export async function expectFee(tx: ContractTransaction, expectedFee: BigNumber) {
  const { events } = await tx.wait();
  const borrowEvents = events!.filter((it) => it.event === "BorrowAtMaturity");
  assert(borrowEvents.length < 2, "searched for one event, but many were found");
  assert(borrowEvents.length > 0, "searched for one event, but none were found");
  const event = borrowEvents[0];
  const lowerBoundary = expectedFee.mul("99").div("100");
  const higherBoundary = expectedFee.mul("101").div("100");
  expect(event!.args!.fee).to.be.gte(lowerBoundary);
  expect(event!.args!.fee).to.be.lte(higherBoundary);
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

export type EnvConfig = {
  mockTokens?: Map<string, MockTokenSpec>;
  useRealInterestRateModel?: boolean;
};

export type MockTokenSpec = {
  decimals: BigNumber | number;
  collateralRate: BigNumber;
  usdPrice: BigNumber;
};

export type MaturityPoolState = {
  borrowFees: BigNumber;
  earningsUnassigned: BigNumber;
  earningsSP: BigNumber;
  earningsAccumulator: BigNumber;
  earningsMP: BigNumber;
  earningsDiscounted: BigNumber;
};

export const defaultMockTokens: Map<string, MockTokenSpec> = new Map([
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

export function decodeMaturities(encodedMaturities: BigNumber): number[] {
  const maturities: number[] = [];
  const baseMaturity = encodedMaturities.mod(BigNumber.from(1).shl(32));
  let packedMaturities = encodedMaturities.shr(32);
  let i = 0;
  while (!packedMaturities.eq(0)) {
    if (packedMaturities.and(1).toNumber() == 1) {
      maturities.push(baseMaturity.add(i * 86400 * 7 * 4).toNumber());
    }
    packedMaturities = packedMaturities.shr(1);
    i++;
  }
  return maturities;
}
