import { ethers } from "hardhat";
import { BigNumber, Contract } from "ethers";
import { applyMaxFee, noDiscount, MaturityPoolState } from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

const {
  constants: { AddressZero },
} = ethers;
export class PoolAccountingEnv {
  mockInterestRateModel: Contract;
  poolAccountingHarness: Contract;
  currentWallet: SignerWithAddress;

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
      .withdrawMPWithReturnValues(maturityPool, this.currentWallet.address, amount, minAmountRequired);
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
      .borrowMPWithReturnValues(maturityPool, this.currentWallet.address, amount, expectedAmount);
  }

  public async setSmartPoolAssets(smartPoolAssets: BigNumber) {
    this.poolAccountingHarness.setSmartPoolAssets(smartPoolAssets);
  }

  static async create(): Promise<PoolAccountingEnv> {
    const MockInterestRateModelFactory = await ethers.getContractFactory("MockInterestRateModel");
    const mockInterestRateModel = await MockInterestRateModelFactory.deploy(0);
    await mockInterestRateModel.deployed();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const asset = await MockERC20.deploy("Fake", "F", 18);
    await asset.deployed();

    const MockOracle = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracle.deploy();
    await oracle.deployed();

    const Auditor = await ethers.getContractFactory("Auditor");
    const auditor = await Auditor.deploy(oracle.address, parseUnits("1.1"));
    await auditor.deployed();

    const PoolAccountingHarness = await ethers.getContractFactory("PoolAccountingHarness");
    const poolAccountingHarness = await PoolAccountingHarness.deploy(
      asset.address,
      3,
      parseUnits("1"),
      auditor.address,
      mockInterestRateModel.address,
      parseUnits("0.02").div(86_400),
      0,
      { up: parseUnits("0.0046"), down: parseUnits("0.42") },
    );
    await poolAccountingHarness.deployed();
    poolAccountingHarness.setSmartPoolAssets(parseUnits("100000"));

    const [owner] = await ethers.getSigners();

    return new PoolAccountingEnv(mockInterestRateModel, poolAccountingHarness, owner);
  }
}
