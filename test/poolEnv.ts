import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";

export class PoolEnv {
  tsUtils: Contract;
  mpHarness: Contract;

  constructor(_tsUtils: Contract, _mpHarness: Contract) {
    this.tsUtils = _tsUtils;
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

  public async depositMoney(amount: string) {
    return this.mpHarness.depositMoney(parseUnits(amount));
  }

  public async repayMoney(amount: string) {
    return this.mpHarness.repayMoney(parseUnits(amount));
  }

  public async addFee(amount: string) {
    return this.mpHarness.addFee(parseUnits(amount));
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

  public async distributeAccordingly(
    earnings: string,
    suppliedSP: string,
    amountFunded: string
  ) {
    return this.mpHarness.distributeAccordingly(
      parseUnits(earnings),
      parseUnits(suppliedSP),
      parseUnits(amountFunded)
    );
  }

  public async scaleProportionally(
    scaledDebtPrincipal: string,
    scaledDebtFee: string,
    amount: string
  ) {
    return this.mpHarness.scaleProportionally(
      parseUnits(scaledDebtPrincipal),
      parseUnits(scaledDebtFee),
      parseUnits(amount)
    );
  }

  public async reduceProportionally(
    scaledDebtPrincipal: string,
    scaledDebtFee: string,
    amount: string
  ) {
    return this.mpHarness.reduceProportionally(
      parseUnits(scaledDebtPrincipal),
      parseUnits(scaledDebtFee),
      parseUnits(amount)
    );
  }

  public async borrowMoney(amount: string, maxDebt: string) {
    return this.mpHarness.borrowMoney(parseUnits(amount), parseUnits(maxDebt));
  }

  public async withdrawMoney(amount: string, maxDebt: string) {
    return this.mpHarness.withdrawMoney(
      parseUnits(amount),
      parseUnits(maxDebt)
    );
  }

  static async create(): Promise<PoolEnv> {
    const TSUtilsLib = await ethers.getContractFactory("TSUtils");
    let tsUtils = await TSUtilsLib.deploy();
    await tsUtils.deployed();

    const MaturityPoolHarness = await ethers.getContractFactory(
      "MaturityPoolHarness",
      {
        libraries: {
          TSUtils: tsUtils.address,
        },
      }
    );
    let maturityPoolHarness = await MaturityPoolHarness.deploy();
    await maturityPoolHarness.deployed();

    return new PoolEnv(tsUtils, maturityPoolHarness);
  }

  /* Replicates PoolLib.sol calculation of unassigned earnings of a maturity pool when calling _accrueAndAddFee function */
  public calculateUnassignedEarnings(
    maturityPoolID: number,
    blockTimestamp: number,
    previousUnassignedEarnings: number,
    secondsSinceLastAccrue: number,
    newFee: number
  ): number {
    return (
      previousUnassignedEarnings -
      (previousUnassignedEarnings * secondsSinceLastAccrue) /
        (maturityPoolID - blockTimestamp + secondsSinceLastAccrue) +
      newFee
    );
  }

  /* Replicates PoolLib.sol calculation of unassigned earnings of a maturity pool when calling addMoney function */
  public calculateUnassignedEarningsWhenDepositingToMP(
    maturityPoolID: number,
    blockTimestamp: number,
    previousUnassignedEarnings: number,
    secondsSinceLastAccrue: number,
    depositedAmount: number,
    suppliedSP: number
  ): number {
    let unassignedEarnings = this.calculateUnassignedEarnings(
      maturityPoolID,
      blockTimestamp,
      previousUnassignedEarnings,
      secondsSinceLastAccrue,
      0 // we calculate unassigned earnings but no new fee is added
    );
    return (
      unassignedEarnings -
      this.calculateLastFee(unassignedEarnings, depositedAmount, suppliedSP)
    );
  }

  /* Replicates PoolLib.sol calculation of smart pool earnings of a maturity pool when calling _accrueAndAddFee function */
  public calculateEarningsSP(
    maturityPoolID: number,
    blockTimestamp: number,
    previousEarningsSP: number,
    previousUnassignedEarnings: number,
    secondsSinceLastAccrue: number
  ): number {
    return (
      (previousUnassignedEarnings * secondsSinceLastAccrue) /
        (maturityPoolID - blockTimestamp + secondsSinceLastAccrue) +
      previousEarningsSP
    );
  }

  /* Replicates PoolLib.sol calculation of earnings share that a depositor will receive after maturity */
  public calculateLastFee(
    previousUnassignedEarnings: number,
    depositedAmount: number,
    suppliedSP: number
  ): number {
    return (
      (previousUnassignedEarnings * depositedAmount) /
      (suppliedSP + depositedAmount)
    );
  }
}
