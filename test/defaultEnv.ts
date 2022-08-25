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
  MockOracle,
  MockOracle__factory,
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
  oracle: MockOracle;
  auditor: Auditor;
  interestRateModel: InterestRateModel | MockInterestRateModel;
  marketContracts: Record<string, Market>;
  underlyingContracts: Record<string, MockERC20 | WETH>;
  baseRate: BigNumber;
  marginRate: BigNumber;
  slopeRate: BigNumber;
  mockAssets: Record<string, MockAssetSpec>;
  notAnMarketAddress = "0x6D88564b707518209a4Bea1a57dDcC23b59036a8";
  currentWallet: SignerWithAddress;
  maxOracleDelayTime: number;

  constructor(
    _oracle: MockOracle,
    _auditor: Auditor,
    _interestRateModel: InterestRateModel | MockInterestRateModel,
    _marketContracts: Record<string, Market>,
    _underlyingContracts: Record<string, MockERC20 | WETH>,
    _mockAssets: Record<string, MockAssetSpec>,
    _currentWallet: SignerWithAddress,
  ) {
    this.oracle = _oracle;
    this.auditor = _auditor;
    this.marketContracts = _marketContracts;
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
        usdPrice: parseUnits("1"),
      },
      WETH: {
        decimals: 18,
        adjustFactor: parseUnits("0.7"),
        usdPrice: parseUnits("3000"),
      },
      WBTC: {
        decimals: 8,
        adjustFactor: parseUnits("0.6"),
        usdPrice: parseUnits("63000"),
      },
      USDC: {
        decimals: 6,
        adjustFactor: parseUnits("0.8"),
        usdPrice: parseUnits("1"),
      },
    };
    const marketContracts: Record<string, Market> = {};
    const underlyingContracts: Record<string, MockERC20 | WETH> = {};

    const owner = await getNamedSigner("deployer");

    const MockOracle = (await getContractFactory("MockOracle")) as MockOracle__factory;
    const oracle = await MockOracle.deploy();
    await oracle.deployed();

    const MockInterestRateModelFactory = (await getContractFactory(
      "MockInterestRateModel",
    )) as MockInterestRateModel__factory;

    const InterestRateModelFactory = (await getContractFactory("InterestRateModel")) as InterestRateModel__factory;

    const realInterestRateModel = await InterestRateModelFactory.deploy(
      { a: parseUnits("0.0495"), b: parseUnits("-0.025"), maxUtilization: parseUnits("1.1") },
      { a: parseUnits("0.0495"), b: parseUnits("-0.025"), maxUtilization: parseUnits("1.1") },
    );

    const interestRateModel = config?.useRealInterestRateModel
      ? realInterestRateModel
      : await MockInterestRateModelFactory.deploy(0);
    await interestRateModel.deployed();

    const Auditor = (await getContractFactory("Auditor")) as Auditor__factory;
    const auditorImpl = await Auditor.deploy();
    await auditorImpl.deployed();
    const auditorProxy = await ((await getContractFactory("ERC1967Proxy")) as ERC1967Proxy__factory).deploy(
      auditorImpl.address,
      [],
    );
    await auditorProxy.deployed();
    const auditor = new Contract(auditorProxy.address, Auditor.interface, owner) as Auditor;
    await auditor.initialize(oracle.address, { liquidator: parseUnits("0.1"), lenders: 0 });

    // enable all the Markets in the auditor
    await Promise.all(
      Object.entries(mockAssets).map(async ([symbol, { decimals, adjustFactor, usdPrice }]) => {
        const totalSupply = parseUnits("100000000000", decimals);
        let asset: MockERC20 | WETH;
        if (symbol === "WETH") {
          const Weth = (await getContractFactory("WETH")) as WETH__factory;
          asset = await Weth.deploy();
          await asset.deployed();
          await asset.deposit({ value: totalSupply });
        } else {
          const MockERC20 = (await getContractFactory("MockERC20")) as MockERC20__factory;
          asset = await MockERC20.deploy("Fake " + symbol, "F" + symbol, decimals);
          await asset.deployed();
          await asset.mint(owner.address, totalSupply);
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

        // Mock PriceOracle setting dummy price
        await oracle.setPrice(market.address, usdPrice);
        // Enable Market for MarketASSET by setting the collateral rates
        await auditor.enableMarket(market.address, adjustFactor, decimals);

        // Handy maps with all the markets and underlying assets
        marketContracts[symbol] = market;
        underlyingContracts[symbol] = asset;
      }),
    );

    return new DefaultEnv(oracle, auditor, interestRateModel, marketContracts, underlyingContracts, mockAssets, owner);
  }

  public getMarket(key: string) {
    return this.marketContracts[key];
  }

  public getUnderlying(key: string) {
    return this.underlyingContracts[key];
  }

  public getInterestRateModel(): InterestRateModel | MockInterestRateModel {
    return this.interestRateModel;
  }

  public async setOracle(oracleAddress: string) {
    return this.auditor.connect(this.currentWallet).setOracle(oracleAddress);
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

  public async transfer(assetString: string, wallet: SignerWithAddress, units: string) {
    await this.getUnderlying(assetString)
      .connect(this.currentWallet)
      .transfer(wallet.address, parseUnits(units, this.digitsForAsset(assetString)));
  }

  public digitsForAsset(assetString: string) {
    return this.mockAssets[assetString]?.decimals;
  }

  public async enableMarket(market: string, adjustFactor: BigNumber, decimals: number) {
    return this.auditor.connect(this.currentWallet).enableMarket(market, adjustFactor, decimals);
  }

  public async maturityPool(assetString: string, maturityPoolID: number) {
    const market = this.getMarket(assetString);
    return market.fixedPools(maturityPoolID);
  }

  public async previewDebt(market: string) {
    return this.getMarket(market).previewDebt(this.currentWallet.address);
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
