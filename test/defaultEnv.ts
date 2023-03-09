import { ethers } from "hardhat";
import type { BigNumber, BigNumberish } from "ethers";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
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
  MockInterestRateModel,
  MockInterestRateModel__factory,
  MockPriceFeed,
  MockPriceFeed__factory,
  WETH,
  WETH__factory,
} from "../types";

const {
  utils: { parseUnits },
  getContractFactory,
  getNamedSigner,
  Contract,
  provider,
} = ethers;

/** @deprecated use deploy fixture */
export class DefaultEnv {
  auditor: Auditor;
  interestRateModel: InterestRateModel | MockInterestRateModel;
  marketContracts: Record<string, Market>;
  priceFeeds: Record<string, MockPriceFeed>;
  underlyingContracts: Record<string, MockERC20 | WETH>;
  baseRate: BigNumber;
  marginRate: BigNumber;
  slopeRate: BigNumber;
  mockAssets: Record<string, MockAssetSpec>;
  notAnMarketAddress = "0x6D88564b707518209a4Bea1a57dDcC23b59036a8";
  currentWallet: SignerWithAddress;
  maxOracleDelayTime: number;

  constructor(
    _auditor: Auditor,
    _interestRateModel: InterestRateModel | MockInterestRateModel,
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

    const MockInterestRateModelFactory = (await getContractFactory(
      "MockInterestRateModel",
    )) as MockInterestRateModel__factory;

    const InterestRateModelFactory = (await getContractFactory("InterestRateModel")) as InterestRateModel__factory;

    const realInterestRateModel = await InterestRateModelFactory.deploy(
      parseUnits("0.0495"),
      parseUnits("-0.025"),
      parseUnits("1.1"),
      parseUnits("0.0495"),
      parseUnits("-0.025"),
      parseUnits("1.1"),
    );

    const interestRateModel = config?.useRealInterestRateModel
      ? realInterestRateModel
      : await MockInterestRateModelFactory.deploy(0);
    await interestRateModel.deployed();

    const Auditor = (await getContractFactory("Auditor")) as Auditor__factory;
    const auditorImpl = await Auditor.deploy(8);
    await auditorImpl.deployed();
    const auditorProxy = await ((await getContractFactory("ERC1967Proxy")) as ERC1967Proxy__factory).deploy(
      auditorImpl.address,
      [],
    );
    await auditorProxy.deployed();
    const auditor = new Contract(auditorProxy.address, Auditor.interface, owner) as Auditor;
    await auditor.initialize({ liquidator: parseUnits("0.1"), lenders: 0 });

    // enable all the Markets in the auditor
    await Promise.all(
      Object.entries(mockAssets).map(async ([symbol, { decimals, adjustFactor, usdPrice }]) => {
        let asset: MockERC20 | WETH;
        if (symbol === "WETH") {
          const Weth = (await getContractFactory("WETH")) as WETH__factory;
          asset = await Weth.deploy();
          await asset.deployed();
          await asset.deposit({ value: parseUnits("100", decimals) });
        } else {
          const MockERC20 = (await getContractFactory("MockERC20")) as MockERC20__factory;
          asset = await MockERC20.deploy("Fake " + symbol, "F" + symbol, decimals);
          await asset.deployed();
          await asset.mint(owner.address, parseUnits("100000000000", decimals));
        }

        const Market = (await getContractFactory("Market")) as Market__factory;
        const marketImpl = await Market.deploy(asset.address, auditor.address);
        await marketImpl.deployed();
        const marketProxy = await ((await getContractFactory("ERC1967Proxy")) as ERC1967Proxy__factory).deploy(
          marketImpl.address,
          [],
        );
        await marketProxy.deployed();
        const market = new Contract(marketProxy.address, Market.interface, owner) as Market;
        await market.initialize(
          12,
          parseUnits("1"),
          interestRateModel.address,
          parseUnits("0.02").div(86_400),
          0, // SP rate if 0 then no fees charged for the mp depositors' yield
          0,
          parseUnits("0.0046"),
          parseUnits("0.42"),
        );

        // deploy a MockPriceFeed setting dummy price
        const MockPriceFeed = (await getContractFactory("MockPriceFeed")) as MockPriceFeed__factory;
        const mockPriceFeed = await MockPriceFeed.deploy(8, usdPrice);
        await mockPriceFeed.deployed();
        // Enable Market for MarketASSET by setting the collateral rates
        await auditor.enableMarket(market.address, mockPriceFeed.address, adjustFactor);

        // Handy maps with all the markets and underlying assets
        priceFeeds[market.address] = mockPriceFeed;
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
    await asset.connect(this.currentWallet).approve(market.address, amount);
    return market.connect(this.currentWallet).deposit(amount, this.currentWallet.address);
  }

  public async depositMP(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    const asset = this.getUnderlying(assetString);
    const market = this.getMarket(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    const expectedAmount =
      (expectedAtMaturity && parseUnits(expectedAtMaturity, this.digitsForAsset(assetString))) || amount;
    await asset.connect(this.currentWallet).approve(market.address, amount);
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
    let expectedAmount: BigNumber;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity, this.digitsForAsset(assetString));
    } else {
      expectedAmount = amount.sub(amount.div(10)); // 10%
    }
    return market
      .connect(this.currentWallet)
      .withdrawAtMaturity(maturityPool, amount, expectedAmount, this.currentWallet.address, this.currentWallet.address);
  }

  public async borrowMP(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    const market = this.getMarket(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: BigNumber;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity, this.digitsForAsset(assetString));
    } else {
      expectedAmount = amount.add(amount.div(10)); // 10%
    }
    return market
      .connect(this.currentWallet)
      .borrowAtMaturity(maturityPool, amount, expectedAmount, this.currentWallet.address, this.currentWallet.address);
  }

  public async repayMP(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    const asset = this.getUnderlying(assetString);
    const market = this.getMarket(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: BigNumber;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity, this.digitsForAsset(assetString));
    } else {
      expectedAmount = amount;
    }
    await asset.connect(this.currentWallet).approve(market.address, amount);
    return market
      .connect(this.currentWallet)
      .repayAtMaturity(maturityPool, amount, expectedAmount, this.currentWallet.address);
  }

  public async enterMarket(asset: string) {
    const market = this.getMarket(asset).address;
    return this.auditor.connect(this.currentWallet).enterMarket(market);
  }

  public async setBorrowRate(rate: string) {
    await (this.interestRateModel.connect(this.currentWallet) as MockInterestRateModel).setBorrowRate(parseUnits(rate));
  }

  public async setFixedParameters(a: BigNumber, b: BigNumber, maxU: BigNumber) {
    const irmFactory = (await getContractFactory("InterestRateModel")) as InterestRateModel__factory;
    const irm = this.interestRateModel as InterestRateModel;
    const newIRM = await irmFactory.deploy(
      a,
      b,
      maxU,
      ...(await Promise.all([irm.floatingCurveA(), irm.floatingCurveB(), irm.floatingMaxUtilization()])),
    );

    this.interestRateModel = newIRM;
    for (const market of Object.values(this.marketContracts)) await market.setInterestRateModel(newIRM.address);
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

  public async setPrice(market: string, price: BigNumber) {
    return this.priceFeeds[market].setPrice(price);
  }
}

type EnvConfig = {
  mockAssets?: Record<string, MockAssetSpec>;
  useRealInterestRateModel?: boolean;
};

type MockAssetSpec = {
  decimals: BigNumberish;
  adjustFactor: BigNumber;
  usdPrice: BigNumber;
};
