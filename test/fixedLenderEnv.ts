import { ethers } from "hardhat";
import { BigNumber, Contract } from "ethers";
import { FixedPoolState } from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

export class FixedLenderEnv {
  mockInterestRateModel: Contract;
  fixedLenderHarness: Contract;
  asset: Contract;
  currentWallet: SignerWithAddress;

  constructor(
    mockInterestRateModel_: Contract,
    fixedLenderHarness_: Contract,
    asset_: Contract,
    currentWallet_: SignerWithAddress,
  ) {
    this.mockInterestRateModel = mockInterestRateModel_;
    this.fixedLenderHarness = fixedLenderHarness_;
    this.asset = asset_;
    this.currentWallet = currentWallet_;
  }

  public async moveInTime(timestamp: number) {
    return ethers.provider.send("evm_setNextBlockTimestamp", [timestamp]);
  }

  public switchWallet(wallet: SignerWithAddress) {
    this.currentWallet = wallet;
  }

  public getAllEarnings(fixedPoolState: FixedPoolState): BigNumber {
    return fixedPoolState.earningsSP
      .add(fixedPoolState.earningsAccumulator)
      .add(fixedPoolState.earningsMP)
      .add(fixedPoolState.earningsUnassigned)
      .add(fixedPoolState.earningsDiscounted);
  }

  static async create(): Promise<FixedLenderEnv> {
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
    const auditor = await Auditor.deploy(oracle.address, { liquidator: parseUnits("0.1"), lenders: 0 });
    await auditor.deployed();

    const FixedLenderHarness = await ethers.getContractFactory("FixedLenderHarness");
    const fixedLenderHarness = await FixedLenderHarness.deploy(
      asset.address,
      4,
      parseUnits("1"),
      auditor.address,
      mockInterestRateModel.address,
      parseUnits("0.02").div(86_400),
      0,
      { up: parseUnits("0.0046"), down: parseUnits("0.42") },
    );
    await fixedLenderHarness.deployed();
    await oracle.setPrice(fixedLenderHarness.address, parseUnits("1"));
    await auditor.enableMarket(fixedLenderHarness.address, parseUnits("0.9"), 18);

    const [owner] = await ethers.getSigners();

    return new FixedLenderEnv(mockInterestRateModel, fixedLenderHarness, asset, owner);
  }
}
