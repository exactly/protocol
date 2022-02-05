import { ethers } from "hardhat";
import { BigNumber, Contract } from "ethers";
import { applyMaxFee, noDiscount } from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

export class PoolAccountingEnv {
  interestRateModel: Contract;
  realPoolAccounting: Contract;
  poolAccountingHarness: Contract;
  currentWallet: SignerWithAddress;
  maxSPDebt = parseUnits("100000");

  constructor(
    _interestRateModel: Contract,
    _realPoolAccounting: Contract,
    _poolAccountingHarness: Contract,
    _currentWallet: SignerWithAddress
  ) {
    this.interestRateModel = _interestRateModel;
    this.realPoolAccounting = _realPoolAccounting;
    this.poolAccountingHarness = _poolAccountingHarness;
    this.currentWallet = _currentWallet;
  }

  public async moveInTime(timestamp: number) {
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
      .repayMP(
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
      .depositMP(
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
      .borrowMP(
        maturityPool,
        this.currentWallet.address,
        amount,
        expectedAmount,
        this.maxSPDebt
      );
  }

  static async create(): Promise<PoolAccountingEnv> {
    const MockedInterestRateModel = await ethers.getContractFactory(
      "MockedInterestRateModel"
    );
    const mockedInterestRateModel = await MockedInterestRateModel.deploy();
    await mockedInterestRateModel.deployed();
    const TSUtilsLib = await ethers.getContractFactory("TSUtils");
    let tsUtils = await TSUtilsLib.deploy();
    await tsUtils.deployed();
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
      mockedInterestRateModel.address
    );
    await realPoolAccounting.deployed();
    const PoolAccountingHarness = await ethers.getContractFactory(
      "PoolAccountingHarness"
    );
    const poolAccountingHarness = await PoolAccountingHarness.deploy(
      realPoolAccounting.address
    );
    await poolAccountingHarness.deployed();

    const [owner] = await ethers.getSigners();

    await realPoolAccounting.initialize(poolAccountingHarness.address);
    return new PoolAccountingEnv(
      mockedInterestRateModel,
      realPoolAccounting,
      poolAccountingHarness,
      owner
    );
  }
}
