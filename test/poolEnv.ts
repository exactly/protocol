import { ethers } from "hardhat";
import type { FixedPoolHarness, FixedPoolHarness__factory } from "../types";

const {
  utils: { parseUnits },
  getContractFactory,
  provider,
} = ethers;

/** @deprecated use deploy fixture */
export class PoolEnv {
  fpHarness: FixedPoolHarness;

  constructor(_fpHarness: FixedPoolHarness) {
    this.fpHarness = _fpHarness;
  }

  public getFpHarness(): FixedPoolHarness {
    return this.fpHarness;
  }

  public async moveInTime(timestamp: number) {
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
  }

  public async accrueEarnings(timestamp: number) {
    return this.fpHarness.accrueEarnings(timestamp);
  }

  public async deposit(amount: string) {
    return this.fpHarness.deposit(parseUnits(amount));
  }

  public async repay(amount: string) {
    return this.fpHarness.repay(parseUnits(amount));
  }

  public async addFee(amount: string) {
    return this.fpHarness.addFee(parseUnits(amount));
  }

  public async setMaturity(encoded: number, timestamp: number) {
    return this.fpHarness.setMaturity(encoded, timestamp);
  }

  public async clearMaturity(encoded: number, timestamp: number) {
    return this.fpHarness.clearMaturity(encoded, timestamp);
  }

  public async removeFee(amount: string) {
    return this.fpHarness.removeFee(parseUnits(amount));
  }

  public async distributeEarnings(earnings: string, suppliedSP: string, borrowAmount: string) {
    return this.fpHarness.distributeEarnings(
      parseUnits(suppliedSP),
      0,
      0,
      0,
      parseUnits(earnings),
      parseUnits(borrowAmount),
    );
  }

  public async scaleProportionally(scaledDebtPrincipal: string, scaledDebtFee: string, amount: string) {
    return this.fpHarness.scaleProportionally(
      parseUnits(scaledDebtPrincipal),
      parseUnits(scaledDebtFee),
      parseUnits(amount),
    );
  }

  public async reduceProportionally(scaledDebtPrincipal: string, scaledDebtFee: string, amount: string) {
    return this.fpHarness.reduceProportionally(
      parseUnits(scaledDebtPrincipal),
      parseUnits(scaledDebtFee),
      parseUnits(amount),
    );
  }

  public async borrow(amount: string) {
    return this.fpHarness.borrow(parseUnits(amount));
  }

  public async withdraw(amount: string) {
    return this.fpHarness.withdraw(parseUnits(amount));
  }

  public async calculateDeposit(amount: string, unassignedEarnings: string, spBorrowed: string, backupFeeRate: string) {
    return this.fpHarness.calculateDeposit(
      parseUnits(spBorrowed),
      0,
      parseUnits(unassignedEarnings),
      0,
      parseUnits(amount),
      parseUnits(backupFeeRate),
    );
  }

  static async create(): Promise<PoolEnv> {
    const FixedPoolHarness = (await getContractFactory("FixedPoolHarness")) as FixedPoolHarness__factory;
    const fixedPoolHarness = await FixedPoolHarness.deploy();
    await fixedPoolHarness.deployed();

    return new PoolEnv(fixedPoolHarness);
  }
}
