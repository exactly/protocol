import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";

export class PoolEnv {
  mpHarness: Contract;

  constructor(_mpHarness: Contract) {
    this.mpHarness = _mpHarness;
  }

  public getMpHarness(): Contract {
    return this.mpHarness;
  }

  public async moveInTime(timestamp: number) {
    await ethers.provider.send("evm_setNextBlockTimestamp", [timestamp]);
  }

  public async setNextTimestamp(timestamp: number) {
    return this.mpHarness.setNextTimestamp(timestamp);
  }

  public async accrueEarnings(timestamp: number) {
    return this.mpHarness.accrueEarnings(timestamp);
  }

  public async deposit(amount: string) {
    return this.mpHarness.deposit(parseUnits(amount));
  }

  public async repay(amount: string) {
    return this.mpHarness.repay(parseUnits(amount));
  }

  public async addFee(amount: string) {
    return this.mpHarness.addFee(parseUnits(amount));
  }

  public async setMaturity(userBorrows: number, timestamp: number) {
    this.mpHarness.setMaturity(userBorrows, timestamp);
  }

  public async clearMaturity(userBorrows: number, timestamp: number) {
    this.mpHarness.clearMaturity(userBorrows, timestamp);
  }

  public async addFeeMP(amount: string) {
    return this.mpHarness.addFeeMP(parseUnits(amount));
  }

  public async addFeeSP(amount: string) {
    return this.mpHarness.addFeeSP(parseUnits(amount));
  }

  public async removeFee(amount: string) {
    return this.mpHarness.removeFee(parseUnits(amount));
  }

  public async returnFee(amount: string) {
    return this.mpHarness.returnFee(parseUnits(amount));
  }

  public async distributeEarningsAccordingly(earnings: string, suppliedSP: string, amountFunded: string) {
    return this.mpHarness.distributeEarningsAccordingly(
      parseUnits(earnings),
      parseUnits(suppliedSP),
      parseUnits(amountFunded),
    );
  }

  public async scaleProportionally(scaledDebtPrincipal: string, scaledDebtFee: string, amount: string) {
    return this.mpHarness.scaleProportionally(
      parseUnits(scaledDebtPrincipal),
      parseUnits(scaledDebtFee),
      parseUnits(amount),
    );
  }

  public async reduceProportionally(scaledDebtPrincipal: string, scaledDebtFee: string, amount: string) {
    return this.mpHarness.reduceProportionally(
      parseUnits(scaledDebtPrincipal),
      parseUnits(scaledDebtFee),
      parseUnits(amount),
    );
  }

  public async borrow(amount: string, maxDebt: string) {
    return this.mpHarness.borrow(parseUnits(amount), parseUnits(maxDebt));
  }

  public async withdraw(amount: string, maxDebt: string) {
    return this.mpHarness.withdraw(parseUnits(amount), parseUnits(maxDebt));
  }

  static async create(): Promise<PoolEnv> {
    const MaturityPoolHarness = await ethers.getContractFactory("MaturityPoolHarness");
    let maturityPoolHarness = await MaturityPoolHarness.deploy();
    await maturityPoolHarness.deployed();

    return new PoolEnv(maturityPoolHarness);
  }
}
