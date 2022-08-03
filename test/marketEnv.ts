import { ethers } from "hardhat";
import { parseUnits } from "ethers/lib/utils";
import type { BigNumber } from "ethers";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type {
  Auditor__factory,
  MarketHarness,
  MarketHarness__factory,
  MockERC20,
  MockERC20__factory,
  MockInterestRateModel,
  MockInterestRateModel__factory,
  MockOracle__factory,
} from "../types";

/** @deprecated use deploy fixture */
export class MarketEnv {
  mockInterestRateModel: MockInterestRateModel;
  marketHarness: MarketHarness;
  asset: MockERC20;
  currentWallet: SignerWithAddress;

  constructor(
    mockInterestRateModel_: MockInterestRateModel,
    marketHarness_: MarketHarness,
    asset_: MockERC20,
    currentWallet_: SignerWithAddress,
  ) {
    this.mockInterestRateModel = mockInterestRateModel_;
    this.marketHarness = marketHarness_;
    this.asset = asset_;
    this.currentWallet = currentWallet_;
  }

  public async moveInTime(timestamp: number) {
    return ethers.provider.send("evm_setNextBlockTimestamp", [timestamp]);
  }

  public switchWallet(wallet: SignerWithAddress) {
    this.currentWallet = wallet;
  }

  public getAllEarnings(fixedPoolState: FixedPoolState) {
    return fixedPoolState.backupEarnings
      .add(fixedPoolState.earningsAccumulator)
      .add(fixedPoolState.earningsMP)
      .add(fixedPoolState.unassignedEarnings)
      .add(fixedPoolState.earningsDiscounted);
  }

  static async create() {
    const MockInterestRateModelFactory = (await ethers.getContractFactory(
      "MockInterestRateModel",
    )) as MockInterestRateModel__factory;
    const mockInterestRateModel = await MockInterestRateModelFactory.deploy(0);
    await mockInterestRateModel.deployed();

    const MockERC20 = (await ethers.getContractFactory("MockERC20")) as MockERC20__factory;
    const asset = await MockERC20.deploy("Fake", "F", 18);
    await asset.deployed();

    const MockOracle = (await ethers.getContractFactory("MockOracle")) as MockOracle__factory;
    const oracle = await MockOracle.deploy();
    await oracle.deployed();

    const Auditor = (await ethers.getContractFactory("Auditor")) as Auditor__factory;
    const auditor = await Auditor.deploy(oracle.address, { liquidator: parseUnits("0.1"), lenders: 0 });
    await auditor.deployed();

    const MarketHarness = (await ethers.getContractFactory("MarketHarness")) as MarketHarness__factory;
    const marketHarness = await MarketHarness.deploy(
      asset.address,
      4,
      parseUnits("1"),
      auditor.address,
      mockInterestRateModel.address,
      parseUnits("0.02").div(86_400),
      0, // SP rate if 0 then no fees charged for the mp depositors' yield
      0,
      { up: parseUnits("0.0046"), down: parseUnits("0.42") },
    );
    await marketHarness.deployed();
    await oracle.setPrice(marketHarness.address, parseUnits("1"));
    await auditor.enableMarket(marketHarness.address, parseUnits("0.9"), 18);

    const [owner] = await ethers.getSigners();

    return new MarketEnv(mockInterestRateModel, marketHarness, asset, owner);
  }
}

export type FixedPoolState = {
  borrowFees: BigNumber;
  unassignedEarnings: BigNumber;
  backupEarnings: BigNumber;
  earningsAccumulator: BigNumber;
  earningsMP: BigNumber;
  earningsDiscounted: BigNumber;
};
