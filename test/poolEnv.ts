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
  }

  public async takeMoneyAndAddFee(
    maturityDate: number,
    amount: string,
    feeAmount: string
  ) {
    return this.mpHarness.takeMoneyMP(
      maturityDate,
      parseUnits(amount),
      parseUnits(feeAmount)
    );
  }

  public async accrueEarnings(timestamp: number) {
    return this.mpHarness.accrueEarnings(timestamp);
  }

  public async addMoney(amount: string) {
    return this.mpHarness.addMoney(parseUnits(amount));
  }

  static async create(): Promise<PoolEnv> {
    const MockedInterestRateModelFactory = await ethers.getContractFactory(
      "MockedInterestRateModel"
    );

    const interestRateModel = await MockedInterestRateModelFactory.deploy();
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
        },
      }
    );
    let maturityPoolHarness = await MaturityPoolHarness.deploy(
      eToken.address,
      interestRateModel.address
    );
    await maturityPoolHarness.deployed();

    // This is just for testing purposes of the poollib management
    // since the MaturityPoolHarness needs to be able to mint etokens
    // to have liquiditity to pass the check of Max SP Debt per pool
    await eToken.initialize(
      maturityPoolHarness.address,
      maturityPoolHarness.address
    );
    await maturityPoolHarness.maxMintEToken();

    return new PoolEnv(tsUtils, poolLib, eToken, maturityPoolHarness);
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
