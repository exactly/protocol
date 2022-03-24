import { ethers } from "hardhat";
import { BigNumber, Contract } from "ethers";
import { applyMaxFee, noDiscount, MaturityPoolState } from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

export class PoolAccountingEnv {
  mockInterestRateModel: Contract;
  realInterestRateModel: Contract;
  poolAccountingHarness: Contract;
  currentWallet: SignerWithAddress;
  maxSPDebt = parseUnits("100000"); // we use a high maxSPDebt limit since max borrows are already tested
  nMaturities = 12;

  constructor(
    _mockInterestRateModel: Contract,
    _realInterestRateModel: Contract,
    _poolAccountingHarness: Contract,
    _currentWallet: SignerWithAddress,
  ) {
    this.mockInterestRateModel = _mockInterestRateModel;
    this.realInterestRateModel = _realInterestRateModel;
    this.poolAccountingHarness = _poolAccountingHarness;
    this.currentWallet = _currentWallet;
  }

  public async moveInTime(timestamp: number) {
    return ethers.provider.send("evm_setNextBlockTimestamp", [timestamp]);
  }

  public switchWallet(wallet: SignerWithAddress) {
    this.currentWallet = wallet;
  }

  public getRealInterestRateModel(): Contract {
    return this.realInterestRateModel;
  }

  public getAllEarnings(maturityPoolState: MaturityPoolState): BigNumber {
    return maturityPoolState.earningsSP
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
        this.maxSPDebt,
        this.nMaturities,
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
        this.maxSPDebt,
        this.nMaturities,
      );
  }

  static async create(): Promise<PoolAccountingEnv> {
    const MockInterestRateModelFactory = await ethers.getContractFactory("MockInterestRateModel");
    const InterestRateModelFactory = await ethers.getContractFactory("InterestRateModel");

    const realInterestRateModel = await InterestRateModelFactory.deploy(
      parseUnits("0.07"), // Maturity pool slope rate
      parseUnits("0.07"), // Smart pool slope rate
      parseUnits("0.02"), // Base rate
      parseUnits("0"), // SP rate if 0 then no fees charged for the mp depositors' yield
    );
    await realInterestRateModel.deployed();

    // MockInterestRateModel is wrapping the real IRM since getYieldToDeposit
    // wants to be tested while we might want to hardcode the borrowing rate
    // for testing simplicity
    const mockInterestRateModel = await MockInterestRateModelFactory.deploy(realInterestRateModel.address);
    await mockInterestRateModel.deployed();

    const PoolAccountingHarness = await ethers.getContractFactory("PoolAccountingHarness");
    const poolAccountingHarness = await PoolAccountingHarness.deploy(
      mockInterestRateModel.address,
      parseUnits("0.02").div(86_400),
    );
    await poolAccountingHarness.deployed();
    // We initialize it with itself, so it can call the methods from within
    await poolAccountingHarness.initialize(poolAccountingHarness.address);

    const [owner] = await ethers.getSigners();

    return new PoolAccountingEnv(mockInterestRateModel, realInterestRateModel, poolAccountingHarness, owner);
  }
}
