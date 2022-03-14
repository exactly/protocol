import { ethers } from "hardhat";
import { BigNumber, Contract } from "ethers";
import { applyMaxFee, noDiscount, MaturityPoolState } from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

export class PoolAccountingEnv {
  mockedInterestRateModel: Contract;
  realInterestRateModel: Contract;
  poolAccountingHarness: Contract;
  currentWallet: SignerWithAddress;
  maxSPDebt = parseUnits("100000"); // we use a high maxSPDebt limit since max borrows are already tested
  nMaturities = 12;

  constructor(
    _mockedInterestRateModel: Contract,
    _realInterestRateModel: Contract,
    _poolAccountingHarness: Contract,
    _currentWallet: SignerWithAddress
  ) {
    this.mockedInterestRateModel = _mockedInterestRateModel;
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
      .add(maturityPoolState.earningsTreasury)
      .add(maturityPoolState.earningsUnassigned)
      .add(maturityPoolState.earningsDiscounted);
  }

  public async repayMP(
    maturityPool: number,
    units: string,
    expectedUnits?: string
  ) {
    let expectedAmount: BigNumber;
    let amount = parseUnits(units);
    if (expectedUnits) {
      expectedAmount = parseUnits(expectedUnits);
    } else {
      expectedAmount = noDiscount(amount);
    }
    return this.poolAccountingHarness
      .connect(this.currentWallet)
      .repayMPWithReturnValues(
        maturityPool,
        this.currentWallet.address,
        amount,
        expectedAmount
      );
  }

  public async depositMP(
    maturityPool: number,
    units: string,
    expectedAtMaturity?: string
  ) {
    let expectedAmount: BigNumber;
    let amount = parseUnits(units);
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity);
    } else {
      expectedAmount = noDiscount(amount);
    }
    return this.poolAccountingHarness
      .connect(this.currentWallet)
      .depositMPWithReturnValues(
        maturityPool,
        this.currentWallet.address,
        amount,
        expectedAmount
      );
  }

  public async withdrawMP(
    maturityPool: number,
    units: string,
    expectedAtMaturity?: string
  ) {
    let minAmountRequired: BigNumber;
    let amount = parseUnits(units);
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
        this.nMaturities
      );
  }

  public async borrowMP(
    maturityPool: number,
    units: string,
    expectedAtMaturity?: string
  ) {
    let expectedAmount: BigNumber;
    let amount = parseUnits(units);
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
        this.nMaturities
      );
  }

  static async create(): Promise<PoolAccountingEnv> {
    const TSUtilsLib = await ethers.getContractFactory("TSUtils");
    let tsUtils = await TSUtilsLib.deploy();
    await tsUtils.deployed();

    const MockedInterestRateModelFactory = await ethers.getContractFactory(
      "MockedInterestRateModel"
    );
    const InterestRateModelFactory = await ethers.getContractFactory(
      "InterestRateModel"
    );

    const realInterestRateModel = await InterestRateModelFactory.deploy(
      parseUnits("0.07"), // Maturity pool slope rate
      parseUnits("0.07"), // Smart pool slope rate
      parseUnits("0.02"), // Base rate
      parseUnits("0.0000002315"), // Penalty Rate per second (86400 is ~= 2%)
      parseUnits("0") // SP rate if 0 then no fees charged for the mp depositors' yield
    );
    await realInterestRateModel.deployed();

    // MockedInterestRateModel is wrapping the real IRM since getYieldToDeposit
    // wants to be tested while we might want to hardcode the borrowing rate
    // for testing simplicity
    const mockedInterestRateModel = await MockedInterestRateModelFactory.deploy(
      realInterestRateModel.address
    );
    await mockedInterestRateModel.deployed();

    const PoolAccountingHarness = await ethers.getContractFactory(
      "PoolAccountingHarness",
      {
        libraries: {
          TSUtils: tsUtils.address,
        },
      }
    );
    const poolAccountingHarness = await PoolAccountingHarness.deploy(
      mockedInterestRateModel.address
    );
    await poolAccountingHarness.deployed();
    await poolAccountingHarness.setProtocolSpreadFee(0);
    // We initialize it with itself, so it can call the methods from within
    await poolAccountingHarness.initialize(poolAccountingHarness.address);

    const [owner] = await ethers.getSigners();

    return new PoolAccountingEnv(
      mockedInterestRateModel,
      realInterestRateModel,
      poolAccountingHarness,
      owner
    );
  }
}
