import { ethers } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
  type Auditor,
  type Auditor__factory,
  type ERC1967Proxy__factory,
  type MarketHarness,
  type MarketHarness__factory,
  type MockERC20,
  type MockERC20__factory,
  type MockBorrowRate,
  type MockPriceFeed__factory,
  MockBorrowRate__factory,
  MockSequencerFeed__factory,
} from "../../types";

const { parseUnits, getContractFactory, getNamedSigner, Contract, provider, MaxUint256 } = ethers;

/** @deprecated use deploy fixture */
export class MarketEnv {
  mockInterestRateModel: MockBorrowRate;
  marketHarness: MarketHarness;
  asset: MockERC20;
  currentWallet: SignerWithAddress;

  constructor(
    mockInterestRateModel_: MockBorrowRate,
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
    return provider.send("evm_setNextBlockTimestamp", [timestamp]);
  }

  public switchWallet(wallet: SignerWithAddress) {
    this.currentWallet = wallet;
  }

  public getAllEarnings(fixedPoolState: FixedPoolState) {
    return (
      fixedPoolState.backupEarnings +
      fixedPoolState.earningsAccumulator +
      fixedPoolState.earningsMP +
      fixedPoolState.unassignedEarnings +
      fixedPoolState.earningsDiscounted
    );
  }

  static async create() {
    const owner = await getNamedSigner("deployer");

    const MockBorrowRateFactory = (await getContractFactory("MockBorrowRate")) as MockBorrowRate__factory;
    const mockInterestRateModel = await MockBorrowRateFactory.deploy(0);
    await mockInterestRateModel.waitForDeployment();
    const MockSequencerFeedFactory = (await getContractFactory("MockSequencerFeed")) as MockSequencerFeed__factory;
    const mockSequencerFeed = await MockSequencerFeedFactory.deploy();
    await mockSequencerFeed.waitForDeployment();

    const MockERC20 = (await getContractFactory("MockERC20")) as MockERC20__factory;
    const asset = await MockERC20.deploy("Fake", "F", 18);
    await asset.waitForDeployment();

    const Auditor = (await getContractFactory("Auditor")) as Auditor__factory;
    const auditorImpl = await Auditor.deploy(8, 0);
    await auditorImpl.waitForDeployment();
    const auditorProxy = await ((await getContractFactory("ERC1967Proxy")) as ERC1967Proxy__factory).deploy(
      auditorImpl.target,
      "0x",
    );
    await auditorProxy.waitForDeployment();
    const auditor = new Contract(auditorProxy.target as string, Auditor.interface, owner) as unknown as Auditor;
    await auditor.initialize({ liquidator: parseUnits("0.1"), lenders: 0 }, mockSequencerFeed.target);

    const MarketHarness = (await getContractFactory("MarketHarness")) as MarketHarness__factory;
    const marketHarness = await MarketHarness.deploy(asset.target, auditor.target, {
      assetSymbol: "Fake",
      maxFuturePools: 4,
      maxSupply: MaxUint256,
      earningsAccumulatorSmoothFactor: parseUnits("1"),
      interestRateModel: mockInterestRateModel.target,
      penaltyRate: parseUnits("0.02") / 86_400n,
      backupFeeRate: 0,
      reserveFactor: 0,
      assetsDampSpeedUp: parseUnits("0.0046"),
      assetsDampSpeedDown: parseUnits("0.42"),
      uDampSpeedUp: parseUnits("0.23"),
      uDampSpeedDown: parseUnits("0.000053"),
    });
    await marketHarness.waitForDeployment();
    const MockPriceFeed = (await getContractFactory("MockPriceFeed")) as MockPriceFeed__factory;
    const mockPriceFeed = await MockPriceFeed.deploy(8, parseUnits("1", 8));
    await mockPriceFeed.waitForDeployment();
    await auditor.enableMarket(marketHarness.target, mockPriceFeed.target, parseUnits("0.9"));

    return new MarketEnv(mockInterestRateModel, marketHarness, asset, owner);
  }
}

export type FixedPoolState = {
  borrowFees: bigint;
  unassignedEarnings: bigint;
  backupEarnings: bigint;
  earningsAccumulator: bigint;
  earningsMP: bigint;
  earningsDiscounted: bigint;
};
