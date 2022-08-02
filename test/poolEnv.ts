import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";

/** @deprecated use deploy fixture */
export class PoolEnv {
  fpHarness: Contract;

  constructor(_fpHarness: Contract) {
    this.fpHarness = _fpHarness;
  }

  public getFpHarness(): Contract {
    return this.fpHarness;
  }

  public async moveInTime(timestamp: number) {
    await ethers.provider.send("evm_setNextBlockTimestamp", [timestamp]);
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
    this.fpHarness.setMaturity(encoded, timestamp);
  }

  public async clearMaturity(encoded: number, timestamp: number) {
    this.fpHarness.clearMaturity(encoded, timestamp);
  }

  public async addFeeMP(amount: string) {
    return this.fpHarness.addFeeMP(parseUnits(amount));
  }

  public async addFeeSP(amount: string) {
    return this.fpHarness.addFeeSP(parseUnits(amount));
  }

  public async removeFee(amount: string) {
    return this.fpHarness.removeFee(parseUnits(amount));
  }

  public async returnFee(amount: string) {
    return this.fpHarness.returnFee(parseUnits(amount));
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
    const FixedPoolHarness = await ethers.getContractFactory("FixedPoolHarness");
    const fixedPoolHarness = await FixedPoolHarness.deploy();
    await fixedPoolHarness.deployed();

    return new PoolEnv(fixedPoolHarness);
  }
}
