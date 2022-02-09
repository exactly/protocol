import { ethers } from "hardhat";
import { Contract } from "ethers";

export class PoolAccountingEnv {
  interestRateModel: Contract;
  realPoolAccounting: Contract;
  poolAccountingHarness: Contract;
  fixedLender: Contract;

  constructor(
    _interestRateModel: Contract,
    _realPoolAccounting: Contract,
    _poolAccountingHarness: Contract,
    _fixedLender: Contract
  ) {
    this.interestRateModel = _interestRateModel;
    this.realPoolAccounting = _realPoolAccounting;
    this.poolAccountingHarness = _poolAccountingHarness;
    this.fixedLender = _fixedLender;
  }

  public async moveInTime(timestamp: number) {
    await ethers.provider.send("evm_setNextBlockTimestamp", [timestamp]);
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
    const FixedLender = await ethers.getContractFactory("FixedLender");
    const addressZero = "0x0000000000000000000000000000000000000000";
    // We only deploy a FixedLender to be able to access mpDepositDistributionWeighter parameter and to also call setMpDepositDistributionWeighter
    const fixedLender = await FixedLender.deploy(
      addressZero,
      "DAI",
      addressZero,
      addressZero,
      addressZero
    );
    await fixedLender.deployed();
    const PoolAccountingHarness = await ethers.getContractFactory(
      "PoolAccountingHarness"
    );
    const poolAccountingHarness = await PoolAccountingHarness.deploy(
      realPoolAccounting.address,
      fixedLender.address
    );
    await poolAccountingHarness.deployed();

    await realPoolAccounting.initialize(poolAccountingHarness.address);
    return new PoolAccountingEnv(
      mockedInterestRateModel,
      realPoolAccounting,
      poolAccountingHarness,
      fixedLender
    );
  }
}
