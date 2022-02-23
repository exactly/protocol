import { ethers } from "hardhat";
import { BigNumber, Contract } from "ethers";
import { applyMaxFee, noDiscount } from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

export class PoolAccountingEnv {
  interestRateModel: Contract;
  poolAccountingHarness: Contract;
  currentWallet: SignerWithAddress;
  maxSPDebt = parseUnits("100000");

  constructor(
    _interestRateModel: Contract,
    _poolAccountingHarness: Contract,
    _currentWallet: SignerWithAddress
  ) {
    this.interestRateModel = _interestRateModel;
    this.poolAccountingHarness = _poolAccountingHarness;
    this.currentWallet = _currentWallet;
  }

  public async moveInTime(timestamp: number) {
    await this.poolAccountingHarness.setCurrentTimestamp(timestamp);
    return ethers.provider.send("evm_setNextBlockTimestamp", [timestamp]);
  }

  public switchWallet(wallet: SignerWithAddress) {
    this.currentWallet = wallet;
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
        this.maxSPDebt
      );
  }

  static async create(
    useRealInterestRateModel: boolean = false
  ): Promise<PoolAccountingEnv> {
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

    // MockedInterestRateModel is wrapping the real IRM since getYieldToDeposit
    // wants to be tested while we might want to hardcode the borrowing rate
    // for testing simplicity
    const interestRateModel = useRealInterestRateModel
      ? realInterestRateModel
      : await MockedInterestRateModelFactory.deploy(
          realInterestRateModel.address
        );
    await interestRateModel.deployed();

    const PoolLib = await ethers.getContractFactory("PoolLib", {
      libraries: {
        TSUtils: tsUtils.address,
      },
    });
    let poolLib = await PoolLib.deploy();
    await poolLib.deployed();

    const PoolAccounting = await ethers.getContractFactory("PoolAccounting", {
      libraries: {
        TSUtils: tsUtils.address,
        PoolLib: poolLib.address,
      },
    });
    const realPoolAccounting = await PoolAccounting.deploy(
      interestRateModel.address
    );
    await realPoolAccounting.deployed();
    const PoolAccountingHarness = await ethers.getContractFactory(
      "PoolAccountingHarness",
      {
        libraries: {
          TSUtils: tsUtils.address,
          PoolLib: poolLib.address,
        },
      }
    );
    const poolAccountingHarness = await PoolAccountingHarness.deploy(
      interestRateModel.address
    );
    await poolAccountingHarness.deployed();
    // We initialize it with itself, so it can call the methods from within
    await poolAccountingHarness.initialize(poolAccountingHarness.address);

    const [owner] = await ethers.getSigners();

    return new PoolAccountingEnv(
      interestRateModel,
      poolAccountingHarness,
      owner
    );
  }
}
