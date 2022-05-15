import { ethers } from "hardhat";
import { BigNumber, Contract } from "ethers";
import { applyMaxFee, noDiscount, MaturityPoolState } from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

export class PoolAccountingEnv {
  mockInterestRateModel: Contract;
  poolAccountingHarness: Contract;
  currentWallet: SignerWithAddress;
  smartPoolTotalSupply = parseUnits("100000"); // we use a high smartPoolTotalSupply limit since max borrows are already tested

  constructor(_mockInterestRateModel: Contract, _poolAccountingHarness: Contract, _currentWallet: SignerWithAddress) {
    this.mockInterestRateModel = _mockInterestRateModel;
    this.poolAccountingHarness = _poolAccountingHarness;
    this.currentWallet = _currentWallet;
  }

  public async moveInTime(timestamp: number) {
    return ethers.provider.send("evm_setNextBlockTimestamp", [timestamp]);
  }

  public switchWallet(wallet: SignerWithAddress) {
    this.currentWallet = wallet;
  }

  public getAllEarnings(maturityPoolState: MaturityPoolState): BigNumber {
    return maturityPoolState.earningsSP
      .add(maturityPoolState.earningsAccumulator)
      .add(maturityPoolState.earningsMP)
      .add(maturityPoolState.earningsUnassigned)
      .add(maturityPoolState.earningsDiscounted);
  }

  public async repayMP(maturityPool: number, units: string, expectedUnits?: string) {
    let expectedAmount: BigNumber;
    const amount = parseUnits(units);
    if (expectedUnits) {
      expectedAmount = parseUnits(expectedUnits);
    } else {
      expectedAmount = noDiscount(amount);
    }
    return this.poolAccountingHarness
      .connect(this.currentWallet)
      .repayMPWithReturnValues(maturityPool, this.currentWallet.address, amount, expectedAmount);
  }

  public async depositMP(maturityPool: number, units: string, expectedAtMaturity?: string) {
    let expectedAmount: BigNumber;
    const amount = parseUnits(units);
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity);
    } else {
      expectedAmount = noDiscount(amount);
    }
    return this.poolAccountingHarness
      .connect(this.currentWallet)
      .depositMPWithReturnValues(maturityPool, this.currentWallet.address, amount, expectedAmount);
  }

  public async withdrawMP(maturityPool: number, units: string, expectedAtMaturity?: string) {
    let minAmountRequired: BigNumber;
    const amount = parseUnits(units);
    if (expectedAtMaturity) {
      minAmountRequired = parseUnits(expectedAtMaturity);
    } else {
      minAmountRequired = noDiscount(amount);
    }
    return this.poolAccountingHarness
      .connect(this.currentWallet)
      .withdrawMPWithReturnValues(
        maturityPool,
        this.currentWallet.address,
        amount,
        minAmountRequired,
        this.smartPoolTotalSupply,
      );
  }

  public async borrowMP(maturityPool: number, units: string, expectedAtMaturity?: string) {
    let expectedAmount: BigNumber;
    const amount = parseUnits(units);
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity);
    } else {
      expectedAmount = applyMaxFee(amount);
    }
    return this.poolAccountingHarness
      .connect(this.currentWallet)
      .borrowMPWithReturnValues(
        maturityPool,
        this.currentWallet.address,
        amount,
        expectedAmount,
        this.smartPoolTotalSupply,
      );
  }

  static async create(): Promise<PoolAccountingEnv> {
    const MockInterestRateModelFactory = await ethers.getContractFactory("MockInterestRateModel");
    const mockInterestRateModel = await MockInterestRateModelFactory.deploy(0);
    await mockInterestRateModel.deployed();

    const PoolAccountingHarness = await ethers.getContractFactory("PoolAccountingHarness");
    const poolAccountingHarness = await PoolAccountingHarness.deploy(
      mockInterestRateModel.address,
      parseUnits("0.02").div(86_400),
      0,
      { up: parseUnits("0.0046"), down: parseUnits("0.42") },
    );
    await poolAccountingHarness.deployed();

    const [owner] = await ethers.getSigners();

    return new PoolAccountingEnv(mockInterestRateModel, poolAccountingHarness, owner);
  }
}
