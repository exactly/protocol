import { ethers } from "hardhat";
import type { Addressable, BigNumberish } from "ethers";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type {
  Auditor,
  Auditor__factory,
  ERC1967Proxy__factory,
  InterestRateModel,
  InterestRateModel__factory,
  Market,
  Market__factory,
  MockERC20,
  MockERC20__factory,
  MockBorrowRate,
  MockBorrowRate__factory,
  MockPriceFeed,
  MockPriceFeed__factory,
  MockSequencerFeed__factory,
  WETH,
  WETH__factory,
} from "../../types";

const { ZeroAddress, parseUnits, getContractFactory, getNamedSigner, Contract, provider, MaxUint256 } = ethers;

/** @deprecated use deploy fixture */
export class DefaultEnv {
  auditor: Auditor;
  interestRateModel: InterestRateModel | MockBorrowRate;
  marketContracts: Record<string, Market>;
  priceFeeds: Record<string, MockPriceFeed>;
  underlyingContracts: Record<string, MockERC20 | WETH>;
  baseRate: bigint;
  marginRate: bigint;
  slopeRate: bigint;
  mockAssets: Record<string, MockAssetSpec>;
  notAnMarketAddress = "0x6D88564b707518209a4Bea1a57dDcC23b59036a8";
  currentWallet: SignerWithAddress;
  maxOracleDelayTime: number;

  constructor(
    _auditor: Auditor,
    _interestRateModel: InterestRateModel | MockBorrowRate,
    _marketContracts: Record<string, Market>,
    _priceFeeds: Record<string, MockPriceFeed>,
    _underlyingContracts: Record<string, MockERC20 | WETH>,
    _mockAssets: Record<string, MockAssetSpec>,
    _currentWallet: SignerWithAddress,
  ) {
    this.auditor = _auditor;
    this.marketContracts = _marketContracts;
    this.priceFeeds = _priceFeeds;
    this.underlyingContracts = _underlyingContracts;
    this.interestRateModel = _interestRateModel;
    this.mockAssets = _mockAssets;
    this.baseRate = parseUnits("0.02");
    this.marginRate = parseUnits("0.01");
    this.slopeRate = parseUnits("0.07");
    this.currentWallet = _currentWallet;
    this.maxOracleDelayTime = 3600; // 1 hour
  }

  static async create(config?: EnvConfig): Promise<DefaultEnv> {
    const mockAssets = config?.mockAssets ?? {
      DAI: {
        decimals: 18,
        adjustFactor: parseUnits("0.8"),
        usdPrice: parseUnits("1", 8),
      },
      WETH: {
        decimals: 18,
        adjustFactor: parseUnits("0.7"),
        usdPrice: parseUnits("3000", 8),
      },
      WBTC: {
        decimals: 8,
        adjustFactor: parseUnits("0.6"),
        usdPrice: parseUnits("63000", 8),
      },
      USDC: {
        decimals: 6,
        adjustFactor: parseUnits("0.8"),
        usdPrice: parseUnits("1", 8),
      },
    };
    const marketContracts: Record<string, Market> = {};
    const priceFeeds: Record<string, MockPriceFeed> = {};
    const underlyingContracts: Record<string, MockERC20 | WETH> = {};

    const owner = await getNamedSigner("deployer");

    const MockBorrowRateFactory = (await getContractFactory("MockBorrowRate")) as MockBorrowRate__factory;

    const MockSequencerFeedFactory = (await getContractFactory("MockSequencerFeed")) as MockSequencerFeed__factory;

    const InterestRateModelFactory = (await getContractFactory("InterestRateModel")) as InterestRateModel__factory;

    const realInterestRateModel = await InterestRateModelFactory.deploy(
      {
        minRate: parseUnits("0.035"),
        naturalRate: parseUnits("0.08"),
        maxUtilization: parseUnits("1.1"),
        naturalUtilization: parseUnits("0.75"),
        growthSpeed: parseUnits("1.1"),
        sigmoidSpeed: parseUnits("2.5"),
        spreadFactor: parseUnits("0.2"),
        maturitySpeed: parseUnits("0.5"),
        timePreference: parseUnits("0.01"),
        fixedAllocation: parseUnits("0.6"),
        maxRate: parseUnits("10"),
        maturityDurationSpeed: parseUnits("0.5"),
        durationThreshold: parseUnits("0.2"),
        durationGrowthLaw: parseUnits("1"),
        penaltyDurationFactor: parseUnits("1.333"),
        fixedBorrowThreshold: parseUnits("0.6"),
        curveFactor: parseUnits("0.5"),
        minThresholdFactor: parseUnits("0.25"),
      },
      ZeroAddress,
    );

    const interestRateModel = config?.useRealInterestRateModel
      ? realInterestRateModel
      : await MockBorrowRateFactory.deploy(0);
    await interestRateModel.waitForDeployment();
    const mockSequencerFeed = await MockSequencerFeedFactory.deploy();
    await mockSequencerFeed.waitForDeployment();

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

    // enable all the Markets in the auditor
    await Promise.all(
      Object.entries(mockAssets).map(async ([symbol, { decimals, adjustFactor, usdPrice }]) => {
        let asset: MockERC20 | WETH;
        if (symbol === "WETH") {
          const Weth = (await getContractFactory("WETH")) as WETH__factory;
          asset = await Weth.deploy();
          await asset.waitForDeployment();
          await asset.deposit({ value: parseUnits("100", decimals) });
        } else {
          const MockERC20 = (await getContractFactory("MockERC20")) as MockERC20__factory;
          asset = await MockERC20.deploy("Fake " + symbol, "F" + symbol, decimals);
          await asset.waitForDeployment();
          await asset.mint(owner.address, parseUnits("100000000000", decimals));
        }

        const Market = (await getContractFactory("Market")) as Market__factory;
        const marketImpl = await Market.deploy(asset.target, auditor.target);
        await marketImpl.waitForDeployment();
        const marketProxy = await ((await getContractFactory("ERC1967Proxy")) as ERC1967Proxy__factory).deploy(
          marketImpl.target,
          "0x",
        );
        await marketProxy.waitForDeployment();
        const market = new Contract(marketProxy.target as string, Market.interface, owner) as unknown as Market;
        await market.initialize({
          assetSymbol: symbol,
          maxFuturePools: 12,
          maxTotalAssets: MaxUint256,
          earningsAccumulatorSmoothFactor: parseUnits("1"),
          interestRateModel: interestRateModel.target,
          penaltyRate: parseUnits("0.02") / 86_400n,
          backupFeeRate: 0, // SP rate if 0 then no fees charged for the mp depositors' yield
          reserveFactor: 0,
          assetsDampSpeedUp: parseUnits("0.0046"),
          assetsDampSpeedDown: parseUnits("0.42"),
          uDampSpeedUp: parseUnits("0.42"),
          uDampSpeedDown: parseUnits("0.0046"),
        });

        // deploy a MockPriceFeed setting dummy price
        const MockPriceFeed = (await getContractFactory("MockPriceFeed")) as MockPriceFeed__factory;
        const mockPriceFeed = await MockPriceFeed.deploy(8, usdPrice);
        await mockPriceFeed.waitForDeployment();
        // Enable Market for MarketASSET by setting the collateral rates
        await auditor.enableMarket(market.target, mockPriceFeed.target, adjustFactor);

        // Handy maps with all the markets and underlying assets
        priceFeeds[market.target as string] = mockPriceFeed;
        marketContracts[symbol] = market;
        underlyingContracts[symbol] = asset;
      }),
    );

    return new DefaultEnv(
      auditor,
      interestRateModel,
      marketContracts,
      priceFeeds,
      underlyingContracts,
      mockAssets,
      owner,
    );
  }

  public getMarket(key: string) {
    return this.marketContracts[key];
  }

  public getUnderlying(key: string) {
    return this.underlyingContracts[key];
  }

  public switchWallet(wallet: SignerWithAddress) {
    this.currentWallet = wallet;
  }

  public async moveInTime(timestamp: number) {
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
  }

  public async moveInTimeAndMine(timestamp: number) {
    await this.moveInTime(timestamp);
    await provider.send("evm_mine", []);
  }

  public async takeSnapshot() {
    return (await provider.send("evm_snapshot", [])) as string;
  }

  public async revertSnapshot(snapshot: string) {
    await provider.send("evm_revert", [snapshot]);
    await provider.send("evm_mine", []);
  }

  public async depositSP(assetString: string, units: string) {
    const asset = this.getUnderlying(assetString);
    const market = this.getMarket(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    await asset.connect(this.currentWallet).approve(market.target, amount);
    return market.connect(this.currentWallet).deposit(amount, this.currentWallet.address);
  }

  public async depositMP(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    const asset = this.getUnderlying(assetString);
    const market = this.getMarket(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    const expectedAmount =
      (expectedAtMaturity && parseUnits(expectedAtMaturity, this.digitsForAsset(assetString))) || amount;
    await asset.connect(this.currentWallet).approve(market.target, amount);
    return market
      .connect(this.currentWallet)
      .depositAtMaturity(maturityPool, amount, expectedAmount, this.currentWallet.address);
  }

  public async withdrawSP(assetString: string, units: string) {
    const market = this.getMarket(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    return market.connect(this.currentWallet).withdraw(amount, this.currentWallet.address, this.currentWallet.address);
  }

  public async withdrawMP(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    const market = this.getMarket(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: bigint;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity, this.digitsForAsset(assetString));
    } else {
      expectedAmount = amount - amount / 10n; // 10%
    }
    return market
      .connect(this.currentWallet)
      .withdrawAtMaturity(maturityPool, amount, expectedAmount, this.currentWallet.address, this.currentWallet.address);
  }

  public async borrowMP(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    const market = this.getMarket(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: bigint;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity, this.digitsForAsset(assetString));
    } else {
      expectedAmount = amount + amount / 10n; // 10%
    }
    return market
      .connect(this.currentWallet)
      .borrowAtMaturity(maturityPool, amount, expectedAmount, this.currentWallet.address, this.currentWallet.address);
  }

  public async repayMP(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    const asset = this.getUnderlying(assetString);
    const market = this.getMarket(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: bigint;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity, this.digitsForAsset(assetString));
    } else {
      expectedAmount = amount;
    }
    await asset.connect(this.currentWallet).approve(market.target, amount);
    return market
      .connect(this.currentWallet)
      .repayAtMaturity(maturityPool, amount, expectedAmount, this.currentWallet.address);
  }

  public async enterMarket(asset: string) {
    const market = this.getMarket(asset).target;
    return this.auditor.connect(this.currentWallet).enterMarket(market);
  }

  public async setRate(rate: string) {
    await (this.interestRateModel.connect(this.currentWallet) as MockBorrowRate).setRate(parseUnits(rate));
  }

  public async transfer(assetString: string, wallet: SignerWithAddress, units: string) {
    await this.getUnderlying(assetString)
      .connect(this.currentWallet)
      .transfer(wallet.address, parseUnits(units, this.digitsForAsset(assetString)));
  }

  public digitsForAsset(assetString: string) {
    return this.mockAssets[assetString]?.decimals;
  }

  public async maturityPool(assetString: string, maturityPoolID: number) {
    const market = this.getMarket(assetString);
    return market.fixedPools(maturityPoolID);
  }

  public async previewDebt(market: string) {
    return this.getMarket(market).previewDebt(this.currentWallet.address);
  }

  public async setPrice(market: string | Addressable, price: bigint) {
    return this.priceFeeds[market as string].setPrice(price);
  }
}

type EnvConfig = {
  mockAssets?: Record<string, MockAssetSpec>;
  useRealInterestRateModel?: boolean;
};

type MockAssetSpec = {
  decimals: BigNumberish;
  adjustFactor: bigint;
  usdPrice: bigint;
};
