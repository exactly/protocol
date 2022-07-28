import { ethers } from "hardhat";
import { Contract, BigNumber } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  applyMaxFee,
  applyMinFee,
  defaultMockTokens,
  discountMaxFee,
  EnvConfig,
  MockTokenSpec,
  noDiscount,
} from "./exactlyUtils";

export class DefaultEnv {
  oracle: Contract;
  auditor: Contract;
  interestRateModel: Contract;
  marketContracts: Map<string, Contract>;
  underlyingContracts: Map<string, Contract>;
  baseRate: BigNumber;
  marginRate: BigNumber;
  slopeRate: BigNumber;
  mockTokens: Map<string, MockTokenSpec>;
  notAnMarketAddress = "0x6D88564b707518209a4Bea1a57dDcC23b59036a8";
  currentWallet: SignerWithAddress;
  maxOracleDelayTime: number;

  constructor(
    _oracle: Contract,
    _auditor: Contract,
    _interestRateModel: Contract,
    _marketContracts: Map<string, Contract>,
    _underlyingContracts: Map<string, Contract>,
    _mockTokens: Map<string, MockTokenSpec>,
    _currentWallet: SignerWithAddress,
  ) {
    this.oracle = _oracle;
    this.auditor = _auditor;
    this.marketContracts = _marketContracts;
    this.underlyingContracts = _underlyingContracts;
    this.interestRateModel = _interestRateModel;
    this.mockTokens = _mockTokens;
    this.baseRate = parseUnits("0.02");
    this.marginRate = parseUnits("0.01");
    this.slopeRate = parseUnits("0.07");
    this.currentWallet = _currentWallet;
    this.maxOracleDelayTime = 3600; // 1 hour
  }

  static async create({ mockTokens, useRealInterestRateModel }: EnvConfig): Promise<DefaultEnv> {
    if (mockTokens === undefined) {
      mockTokens = defaultMockTokens;
    }
    const marketContracts = new Map<string, Contract>();
    const underlyingContracts = new Map<string, Contract>();

    const MockOracle = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracle.deploy();
    await oracle.deployed();

    const MockInterestRateModelFactory = await ethers.getContractFactory("MockInterestRateModel");

    const InterestRateModelFactory = await ethers.getContractFactory("InterestRateModel");

    const realInterestRateModel = await InterestRateModelFactory.deploy(
      [parseUnits("0.0495"), parseUnits("-0.025"), parseUnits("1.1")],
      parseUnits("1"),
      [parseUnits("0.0495"), parseUnits("-0.025"), parseUnits("1.1")],
      parseUnits("1"),
    );

    const interestRateModel = useRealInterestRateModel
      ? realInterestRateModel
      : await MockInterestRateModelFactory.deploy(0);
    await interestRateModel.deployed();

    const Auditor = await ethers.getContractFactory("Auditor");
    const auditor = await Auditor.deploy(oracle.address, { liquidator: parseUnits("0.1"), lenders: 0 });
    await auditor.deployed();

    const [owner] = await ethers.getSigners();

    // We have to enable all the Markets in the auditor
    await Promise.all(
      Array.from(mockTokens.keys()).map(async (tokenName) => {
        const { decimals, adjustFactor, usdPrice } = mockTokens!.get(tokenName)!;
        const totalSupply = ethers.utils.parseUnits("100000000000", decimals);
        let underlyingToken: Contract;
        if (tokenName === "WETH") {
          const Weth = await ethers.getContractFactory("WETH");
          underlyingToken = await Weth.deploy();
          await underlyingToken.deployed();
          await underlyingToken.deposit({ value: totalSupply });
        } else {
          const MockERC20 = await ethers.getContractFactory("MockERC20");
          underlyingToken = await MockERC20.deploy("Fake " + tokenName, "F" + tokenName, decimals);
          await underlyingToken.deployed();
          await underlyingToken.mint(owner.address, totalSupply);
        }

        const Market = await ethers.getContractFactory("Market");
        const market = await Market.deploy(
          underlyingToken.address,
          12,
          parseUnits("1"),
          auditor.address,
          interestRateModel.address,
          parseUnits("0.02").div(86_400),
          0, // SP rate if 0 then no fees charged for the mp depositors' yield
          0,
          { up: parseUnits("0.0046"), down: parseUnits("0.42") },
        );
        await market.deployed();

        // Mock PriceOracle setting dummy price
        await oracle.setPrice(market.address, usdPrice);
        // Enable Market for Market-TOKEN by setting the collateral rates
        await auditor.enableMarket(market.address, adjustFactor, decimals);

        // Handy maps with all the markets and underlying tokens
        marketContracts.set(tokenName, market);
        underlyingContracts.set(tokenName, underlyingToken);
      }),
    );

    return new DefaultEnv(oracle, auditor, interestRateModel, marketContracts, underlyingContracts, mockTokens!, owner);
  }

  public getMarket(key: string): Contract {
    return this.marketContracts.get(key)!;
  }

  public getUnderlying(key: string): Contract {
    return this.underlyingContracts.get(key)!;
  }

  public getInterestRateModel(): Contract {
    return this.interestRateModel;
  }

  public async setOracle(oracleAddress: string) {
    return this.auditor.connect(this.currentWallet).setOracle(oracleAddress);
  }

  public switchWallet(wallet: SignerWithAddress) {
    this.currentWallet = wallet;
  }

  public async moveInTime(timestamp: number) {
    await ethers.provider.send("evm_setNextBlockTimestamp", [timestamp]);
  }

  public async moveInTimeAndMine(timestamp: number) {
    await this.moveInTime(timestamp);
    await ethers.provider.send("evm_mine", []);
  }

  public async takeSnapshot() {
    const id = await ethers.provider.send("evm_snapshot", []);
    return id;
  }

  public async revertSnapshot(snapshot: any) {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
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
      (expectedAtMaturity && parseUnits(expectedAtMaturity, this.digitsForAsset(assetString))) || applyMinFee(amount);
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
      expectedAmount = discountMaxFee(amount);
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
      expectedAmount = applyMaxFee(amount);
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
      expectedAmount = noDiscount(amount);
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
    await this.interestRateModel.connect(this.currentWallet).setBorrowRate(parseUnits(rate));
  }

  public async transfer(assetString: string, wallet: SignerWithAddress, units: string) {
    await this.getUnderlying(assetString)
      .connect(this.currentWallet)
      .transfer(wallet.address, parseUnits(units, this.digitsForAsset(assetString)));
  }

  public digitsForAsset(assetString: string) {
    return this.mockTokens.get(assetString)!.decimals;
  }

  public async enableMarket(market: string, adjustFactor: BigNumber, decimals: number) {
    return this.auditor.connect(this.currentWallet).enableMarket(market, adjustFactor, decimals);
  }

  public async setLiquidationIncentive(incentive: string) {
    return this.auditor.connect(this.currentWallet).setLiquidationIncentive(parseUnits(incentive));
  }

  public async maturityPool(assetString: string, maturityPoolID: number) {
    const market = this.getMarket(assetString);
    return market.fixedPools(maturityPoolID);
  }

  public async previewDebt(market: string) {
    return this.getMarket(market).previewDebt(this.currentWallet.address);
  }
}
