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
import assert from "assert";

export class SmartPoolState {
  supplied: BigNumber;
  borrowed: BigNumber;
  constructor(_supplied: BigNumber, _borrowed: BigNumber) {
    this.supplied = _supplied;
    this.borrowed = _borrowed;
  }
}

export class DefaultEnv {
  oracle: Contract;
  auditor: Contract;
  interestRateModel: Contract;
  fixedLenderContracts: Map<string, Contract>;
  poolAccountingContracts: Map<string, Contract>;
  underlyingContracts: Map<string, Contract>;
  eTokenContracts: Map<string, Contract>;
  baseRate: BigNumber;
  marginRate: BigNumber;
  slopeRate: BigNumber;
  mockTokens: Map<string, MockTokenSpec>;
  notAnFixedLenderAddress = "0x6D88564b707518209a4Bea1a57dDcC23b59036a8";
  usdAddress: string;
  currentWallet: SignerWithAddress;
  maxOracleDelayTime: number;

  constructor(
    _oracle: Contract,
    _auditor: Contract,
    _interestRateModel: Contract,
    _fixedLenderContracts: Map<string, Contract>,
    _poolAccountingContracts: Map<string, Contract>,
    _underlyingContracts: Map<string, Contract>,
    _eTokenContracts: Map<string, Contract>,
    _mockTokens: Map<string, MockTokenSpec>,
    _currentWallet: SignerWithAddress,
  ) {
    this.oracle = _oracle;
    this.auditor = _auditor;
    this.fixedLenderContracts = _fixedLenderContracts;
    this.poolAccountingContracts = _poolAccountingContracts;
    this.underlyingContracts = _underlyingContracts;
    this.eTokenContracts = _eTokenContracts;
    this.interestRateModel = _interestRateModel;
    this.mockTokens = _mockTokens;
    this.baseRate = parseUnits("0.02");
    this.marginRate = parseUnits("0.01");
    this.slopeRate = parseUnits("0.07");
    this.usdAddress = "0x0000000000000000000000000000000000000348";
    this.currentWallet = _currentWallet;
    this.maxOracleDelayTime = 3600; // 1 hour
  }

  static async create({ mockTokens, useRealInterestRateModel }: EnvConfig): Promise<DefaultEnv> {
    if (mockTokens === undefined) {
      mockTokens = defaultMockTokens;
    }
    const fixedLenderContracts = new Map<string, Contract>();
    const poolAccountingContracts = new Map<string, Contract>();
    const underlyingContracts = new Map<string, Contract>();
    const eTokenContracts = new Map<string, Contract>();

    const MockOracle = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracle.deploy();
    await oracle.deployed();

    const MockInterestRateModelFactory = await ethers.getContractFactory("MockInterestRateModel");

    const InterestRateModelFactory = await ethers.getContractFactory("InterestRateModel");

    const realInterestRateModel = await InterestRateModelFactory.deploy(
      parseUnits("0.0495"), // A parameter for the curve
      parseUnits("-0.025"), // B parameter for the curve
      parseUnits("1.1"), // Max utilization rate
      parseUnits("1"), // Full utilization rate
      parseUnits("0"), // SP rate if 0 then no fees charged for the mp depositors' yield
    );

    const interestRateModel = useRealInterestRateModel
      ? realInterestRateModel
      : await MockInterestRateModelFactory.deploy(realInterestRateModel.address);
    await interestRateModel.deployed();

    const Auditor = await ethers.getContractFactory("Auditor");
    const auditor = await Auditor.deploy(oracle.address);
    await auditor.deployed();

    // We have to enable all the FixedLenders in the auditor
    await Promise.all(
      Array.from(mockTokens.keys()).map(async (tokenName) => {
        const { decimals, collateralRate, usdPrice } = mockTokens!.get(tokenName)!;
        const totalSupply = ethers.utils.parseUnits("100000000000", decimals);
        let underlyingToken: Contract;
        if (tokenName === "WETH") {
          const Weth = await ethers.getContractFactory("WETH");
          underlyingToken = await Weth.deploy();
          await underlyingToken.deployed();
          await underlyingToken.deposit({ value: totalSupply });
        } else {
          const MockToken = await ethers.getContractFactory("MockToken");
          underlyingToken = await MockToken.deploy(
            "Fake " + tokenName,
            "F" + tokenName,
            decimals,
            totalSupply.toString(),
          );
          await underlyingToken.deployed();
        }
        const MockEToken = await ethers.getContractFactory("EToken");
        const eToken = await MockEToken.deploy("eFake " + tokenName, "eF" + tokenName, decimals);
        await eToken.deployed();

        const PoolAccounting = await ethers.getContractFactory("PoolAccounting");
        const poolAccounting = await PoolAccounting.deploy(
          interestRateModel.address,
          parseUnits("0.02").div(86_400),
          parseUnits("0.028"),
        );

        const FixedLender = await ethers.getContractFactory(tokenName === "WETH" ? "ETHFixedLender" : "FixedLender");
        const fixedLender = await FixedLender.deploy(
          underlyingToken.address,
          tokenName,
          eToken.address,
          auditor.address,
          poolAccounting.address,
        );
        await fixedLender.deployed();

        await poolAccounting.initialize(fixedLender.address);
        await eToken.initialize(fixedLender.address, auditor.address);

        // Mock PriceOracle setting dummy price
        await oracle.setPrice(tokenName, usdPrice);
        // Enable Market for FixedLender-TOKEN by setting the collateral rates
        await auditor.enableMarket(fixedLender.address, collateralRate, tokenName, tokenName, decimals);

        // Handy maps with all the fixedLenders and underlying tokens
        fixedLenderContracts.set(tokenName, fixedLender);
        poolAccountingContracts.set(tokenName, poolAccounting);
        underlyingContracts.set(tokenName, underlyingToken);
        eTokenContracts.set(tokenName, eToken);
      }),
    );

    const [owner] = await ethers.getSigners();

    return new DefaultEnv(
      oracle,
      auditor,
      interestRateModel,
      fixedLenderContracts,
      poolAccountingContracts,
      underlyingContracts,
      eTokenContracts,
      mockTokens!,
      owner,
    );
  }

  public getFixedLender(key: string): Contract {
    return this.fixedLenderContracts.get(key)!;
  }

  public getPoolAccounting(key: string): Contract {
    return this.poolAccountingContracts.get(key)!;
  }

  public getUnderlying(key: string): Contract {
    return this.underlyingContracts.get(key)!;
  }

  public getInterestRateModel(): Contract {
    return this.interestRateModel;
  }

  public getEToken(key: string): Contract {
    return this.eTokenContracts.get(key)!;
  }

  public async setOracle(oracleAddress: string) {
    return this.auditor.connect(this.currentWallet).setOracle(oracleAddress);
  }

  public async setOracleMockPrice(assetSymbol: string, valueString: string) {
    await this.oracle.setPrice(assetSymbol, parseUnits(valueString, 18));
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
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    await asset.connect(this.currentWallet).approve(fixedLender.address, amount);
    return fixedLender.connect(this.currentWallet).depositToSmartPool(amount);
  }

  public async depositMP(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    const asset = this.getUnderlying(assetString);
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    const expectedAmount =
      (expectedAtMaturity && parseUnits(expectedAtMaturity, this.digitsForAsset(assetString))) || applyMinFee(amount);
    await asset.connect(this.currentWallet).approve(fixedLender.address, amount);
    return fixedLender.connect(this.currentWallet).depositToMaturityPool(amount, maturityPool, expectedAmount);
  }

  public async depositMPETH(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    assert(assetString === "WETH");
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    const expectedAmount =
      (expectedAtMaturity && parseUnits(expectedAtMaturity, this.digitsForAsset(assetString))) || applyMinFee(amount);
    return fixedLender.connect(this.currentWallet).depositToMaturityPoolEth(maturityPool, expectedAmount, {
      value: amount,
    });
  }

  public async depositSPETH(assetString: string, units: string) {
    assert(assetString === "WETH");
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    return fixedLender.connect(this.currentWallet).depositToSmartPoolEth({ value: amount });
  }

  public async withdrawSP(assetString: string, units: string) {
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    return fixedLender.connect(this.currentWallet).withdrawFromSmartPool(amount);
  }

  public async withdrawSPETH(assetString: string, units: string) {
    assert(assetString === "WETH");
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    return fixedLender.connect(this.currentWallet).withdrawFromSmartPoolEth(amount);
  }

  public async withdrawMPETH(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    assert(assetString === "WETH");
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: BigNumber;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity, this.digitsForAsset(assetString));
    } else {
      expectedAmount = discountMaxFee(amount);
    }
    return fixedLender.connect(this.currentWallet).withdrawFromMaturityPoolEth(amount, expectedAmount, maturityPool);
  }

  public async withdrawMP(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: BigNumber;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity, this.digitsForAsset(assetString));
    } else {
      expectedAmount = discountMaxFee(amount);
    }
    return fixedLender.connect(this.currentWallet).withdrawFromMaturityPool(amount, expectedAmount, maturityPool);
  }

  public async borrowMP(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: BigNumber;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity, this.digitsForAsset(assetString));
    } else {
      expectedAmount = applyMaxFee(amount);
    }
    return fixedLender.connect(this.currentWallet).borrowFromMaturityPool(amount, maturityPool, expectedAmount);
  }

  public async borrowMPETH(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    assert(assetString === "WETH");
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: BigNumber;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity, this.digitsForAsset(assetString));
    } else {
      expectedAmount = applyMaxFee(amount);
    }
    return fixedLender.connect(this.currentWallet).borrowFromMaturityPoolEth(maturityPool, expectedAmount, {
      value: amount,
    });
  }

  public async repayMP(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    const asset = this.getUnderlying(assetString);
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: BigNumber;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity, this.digitsForAsset(assetString));
    } else {
      expectedAmount = noDiscount(amount);
    }
    await asset.connect(this.currentWallet).approve(fixedLender.address, amount);
    return fixedLender
      .connect(this.currentWallet)
      .repayToMaturityPool(this.currentWallet.address, maturityPool, amount, expectedAmount);
  }

  public async repayMPETH(assetString: string, maturityPool: number, units: string, expectedAtMaturity?: string) {
    assert(assetString === "WETH");
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: BigNumber;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(expectedAtMaturity, this.digitsForAsset(assetString));
    } else {
      expectedAmount = noDiscount(amount);
    }
    return fixedLender
      .connect(this.currentWallet)
      .repayToMaturityPoolEth(this.currentWallet.address, maturityPool, expectedAmount, {
        value: amount,
      });
  }

  public async enterMarkets(assets: string[]) {
    const markets = assets.map((asset) => this.getFixedLender(asset).address);
    return this.auditor.connect(this.currentWallet).enterMarkets(markets);
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

  public async enableMarket(
    fixedLender: string,
    collateralFactor: BigNumber,
    symbol: string,
    tokenName: string,
    decimals: number,
  ) {
    return this.auditor
      .connect(this.currentWallet)
      .enableMarket(fixedLender, collateralFactor, symbol, tokenName, decimals);
  }

  public async setLiquidationIncentive(incentive: string) {
    return this.auditor.connect(this.currentWallet).setLiquidationIncentive(parseUnits(incentive));
  }

  public async smartPoolBorrowed(asset: string) {
    return this.getFixedLender(asset).smartPoolBorrowed();
  }

  public async setBorrowCaps(assets: string[], borrowCaps: string[]) {
    assert(assets.length == borrowCaps.length);

    const markets = assets.map((asset) => this.getFixedLender(asset).address);
    const borrowCapsBigNumber = borrowCaps.map((cap, index) => parseUnits(cap, this.digitsForAsset(assets[index])));

    return this.auditor.connect(this.currentWallet).setMarketBorrowCaps(markets, borrowCapsBigNumber);
  }

  public async deployDuplicatedAuditor() {
    const Auditor = await ethers.getContractFactory("Auditor");

    const newAuditor = await Auditor.deploy(this.oracle.address);
    await newAuditor.deployed();
    return newAuditor;
  }

  public async deployNewEToken(name: string, symbol: string, decimals: number) {
    const EToken = await ethers.getContractFactory("EToken");
    const eToken = await EToken.deploy(name, symbol, decimals);
    await eToken.deployed();
    return eToken;
  }

  public async deployNewFixedLender(
    eTokenAddress: string,
    newAuditorAddress: string,
    interestRateModelAddress: string,
    underlyingAddress: string,
    underlyingTokenName: string,
  ) {
    const PoolAccounting = await ethers.getContractFactory("PoolAccounting");
    const poolAccounting = await PoolAccounting.deploy(interestRateModelAddress);
    const FixedLender = await ethers.getContractFactory("FixedLender");
    const fixedLender = await FixedLender.deploy(
      underlyingAddress,
      underlyingTokenName,
      eTokenAddress,
      newAuditorAddress,
      poolAccounting.address,
    );

    await fixedLender.deployed();
    return fixedLender;
  }

  public async smartPoolState(assetString: string) {
    const poolLender = this.getPoolAccounting(assetString);
    const eToken = this.getEToken(assetString);
    return new SmartPoolState(await eToken.totalSupply(), await poolLender.smartPoolBorrowed());
  }

  public async maturityPool(assetString: string, maturityPoolID: number) {
    const poolLender = this.getPoolAccounting(assetString);
    return poolLender.maturityPools(maturityPoolID);
  }

  public async accountSnapshot(assetString: string, maturityPoolID: number) {
    const fixedLender = this.getFixedLender(assetString);
    return fixedLender.getAccountSnapshot(this.currentWallet.address, maturityPoolID);
  }

  public async treasury(assetString: string) {
    const fixedLender = this.getFixedLender(assetString);
    return fixedLender.treasury();
  }
}
