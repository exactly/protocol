import { ethers } from "hardhat";
import { Contract } from "ethers";

export class PoolAccountingEnv {
  interestRateModel: Contract;
  realPoolAccounting: Contract;
  poolAccountingHarness: Contract;

  constructor(
    _interestRateModel: Contract,
    _realPoolAccounting: Contract,
    _poolAccountingHarness: Contract
  ) {
    this.interestRateModel = _interestRateModel;
    this.realPoolAccounting = _realPoolAccounting;
    this.poolAccountingHarness = _poolAccountingHarness;
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
    const PoolAccountingHarness = await ethers.getContractFactory(
      "PoolAccountingHarness"
    );
    const poolAccountingHarness = await PoolAccountingHarness.deploy(
      realPoolAccounting.address
    );
    await poolAccountingHarness.deployed();

    await realPoolAccounting.initialize(poolAccountingHarness.address);
    return new PoolAccountingEnv(
      mockedInterestRateModel,
      realPoolAccounting,
      poolAccountingHarness
    );
  }
}
