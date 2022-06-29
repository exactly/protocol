import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";

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

  public async setNextTimestamp(timestamp: number) {
    return this.fpHarness.setNextTimestamp(timestamp);
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

  public async setMaturity(userBorrows: number, timestamp: number) {
    this.fpHarness.setMaturity(userBorrows, timestamp);
  }

  public async clearMaturity(userBorrows: number, timestamp: number) {
    this.fpHarness.clearMaturity(userBorrows, timestamp);
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

  public async distributeEarningsAccordingly(earnings: string, suppliedSP: string, amountFunded: string) {
    return this.fpHarness.distributeEarningsAccordingly(
      parseUnits(earnings),
      parseUnits(suppliedSP),
      parseUnits(amountFunded),
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

  public async borrow(amount: string, maxDebt: string) {
    return this.fpHarness.borrow(parseUnits(amount), parseUnits(maxDebt));
  }

  public async withdraw(amount: string, maxDebt: string) {
    return this.fpHarness.withdraw(parseUnits(amount), parseUnits(maxDebt));
  }

  public async getDepositYield(
    unassignedEarnings: string,
    amount: string,
    spBorrowed: string,
    smartPoolFeeRate: string,
  ) {
    return this.fpHarness.getDepositYield(
      parseUnits(unassignedEarnings),
      parseUnits(amount),
      parseUnits(spBorrowed),
      parseUnits(smartPoolFeeRate),
    );
  }

  static async create(): Promise<PoolEnv> {
    const FixedPoolHarness = await ethers.getContractFactory("FixedPoolHarness");
    let fixedPoolHarness = await FixedPoolHarness.deploy();
    await fixedPoolHarness.deployed();

    return new PoolEnv(fixedPoolHarness);
  }
}
