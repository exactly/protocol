import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";

export class PoolEnv {
  tsUtils: Contract;
  poolLib: Contract;
  eToken: Contract;
  mpHarness: Contract;

  constructor(
    _tsUtils: Contract,
    _poolLib: Contract,
    _eToken: Contract,
    _mpHarness: Contract
  ) {
    this.tsUtils = _tsUtils;
    this.poolLib = _poolLib;
    this.eToken = _eToken;
    this.mpHarness = _mpHarness;
  }

  public async moveInTime(timestamp: number) {
    await ethers.provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await ethers.provider.send("evm_mine", []);
  }

  public async takeMoney(amount: string) {
    return this.mpHarness.takeMoneyMP(parseUnits(amount));
  }

  public async addFee(timestamp: number, amount: string) {
    return this.mpHarness.addFeeMP(timestamp, parseUnits(amount));
  }

  public async addMoney(timestamp: number, amount: string) {
    return this.mpHarness.addMoneyMP(timestamp, parseUnits(amount));
  }

  public async repay(timestamp: number, amount: string) {
    return this.mpHarness.repayMP(timestamp, parseUnits(amount));
  }

  static async create(): Promise<PoolEnv> {
    const TSUtilsLib = await ethers.getContractFactory("TSUtils");
    let tsUtils = await TSUtilsLib.deploy();
    await tsUtils.deployed();

    const EToken = await ethers.getContractFactory("EToken", {});
    let eToken = await EToken.deploy("eDAI", "eDAI", 18);
    await eToken.deployed();

    const PoolLib = await ethers.getContractFactory("PoolLib", {
      libraries: {
        TSUtils: tsUtils.address,
      },
    });
    const poolLib = await PoolLib.deploy();
    await poolLib.deployed();

    const MaturityPoolHarness = await ethers.getContractFactory(
      "MaturityPoolHarness",
      {
        libraries: {
          PoolLib: poolLib.address,
          TSUtils: tsUtils.address,
        },
      }
    );
    let maturityPoolHarness = await MaturityPoolHarness.deploy(eToken.address);
    await maturityPoolHarness.deployed();

    return new PoolEnv(tsUtils, poolLib, eToken, maturityPoolHarness);
  }
}
