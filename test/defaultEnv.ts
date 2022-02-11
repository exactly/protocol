import { ethers } from "hardhat";
import { Contract, BigNumber } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  applyMaxFee,
  applyMinFee,
  defaultMockedTokens,
  EnvConfig,
  MockedTokenSpec,
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
  tsUtils: Contract;
  poolLib: Contract;
  marketsLib: Contract;
  fixedLenderContracts: Map<string, Contract>;
  poolAccountingContracts: Map<string, Contract>;
  underlyingContracts: Map<string, Contract>;
  eTokenContracts: Map<string, Contract>;
  baseRate: BigNumber;
  marginRate: BigNumber;
  slopeRate: BigNumber;
  mockedTokens: Map<string, MockedTokenSpec>;
  notAnFixedLenderAddress = "0x6D88564b707518209a4Bea1a57dDcC23b59036a8";
  usdAddress: string;
  currentWallet: SignerWithAddress;

  constructor(
    _oracle: Contract,
    _auditor: Contract,
    _interestRateModel: Contract,
    _tsUtils: Contract,
    _poolLib: Contract,
    _marketsLib: Contract,
    _fixedLenderContracts: Map<string, Contract>,
    _poolAccountingContracts: Map<string, Contract>,
    _underlyingContracts: Map<string, Contract>,
    _eTokenContracts: Map<string, Contract>,
    _mockedTokens: Map<string, MockedTokenSpec>,
    _currentWallet: SignerWithAddress
  ) {
    this.oracle = _oracle;
    this.auditor = _auditor;
    this.fixedLenderContracts = _fixedLenderContracts;
    this.poolAccountingContracts = _poolAccountingContracts;
    this.underlyingContracts = _underlyingContracts;
    this.eTokenContracts = _eTokenContracts;
    this.interestRateModel = _interestRateModel;
    this.tsUtils = _tsUtils;
    this.poolLib = _poolLib;
    this.mockedTokens = _mockedTokens;
    this.marketsLib = _marketsLib;
    this.baseRate = parseUnits("0.02");
    this.marginRate = parseUnits("0.01");
    this.slopeRate = parseUnits("0.07");
    this.usdAddress = "0x0000000000000000000000000000000000000348";
    this.currentWallet = _currentWallet;
  }

  static async create({
    mockedTokens,
    useRealInterestRateModel,
  }: EnvConfig): Promise<DefaultEnv> {
    if (mockedTokens === undefined) {
      mockedTokens = defaultMockedTokens;
    }
    let fixedLenderContracts = new Map<string, Contract>();
    let poolAccountingContracts = new Map<string, Contract>();
    let underlyingContracts = new Map<string, Contract>();
    let eTokenContracts = new Map<string, Contract>();

    const TSUtilsLib = await ethers.getContractFactory("TSUtils");
    let tsUtils = await TSUtilsLib.deploy();
    await tsUtils.deployed();

    const PoolLib = await ethers.getContractFactory("PoolLib", {
      libraries: {
        TSUtils: tsUtils.address,
      },
    });
    const poolLib = await PoolLib.deploy();
    await poolLib.deployed();

    const MarketsLib = await ethers.getContractFactory("MarketsLib");
    let marketsLib = await MarketsLib.deploy();
    await marketsLib.deployed();

    const MockedOracle = await ethers.getContractFactory("MockedOracle");
    let oracle = await MockedOracle.deploy();
    await oracle.deployed();

    const MockedInterestRateModelFactory = await ethers.getContractFactory(
      "MockedInterestRateModel"
    );

    const InterestRateModelFactory = await ethers.getContractFactory(
      "InterestRateModel",
      {
        libraries: {
          TSUtils: tsUtils.address,
        },
      }
    );

    const interestRateModel = useRealInterestRateModel
      ? await InterestRateModelFactory.deploy(
          parseUnits("0.07"), // Maturity pool slope rate
          parseUnits("0.07"), // Smart pool slope rate
          parseUnits("0.4"), // High UR slope rate
          parseUnits("0.8"), // Slope change rate
          parseUnits("0.02"), // Base rate
          parseUnits("0.0000002315") // Penalty Rate per second (86400 is ~= 2%)
        )
      : await MockedInterestRateModelFactory.deploy();
    await interestRateModel.deployed();

    const Auditor = await ethers.getContractFactory("Auditor", {
      libraries: {
        TSUtils: tsUtils.address,
        MarketsLib: marketsLib.address,
      },
    });
    let auditor = await Auditor.deploy(oracle.address);
    await auditor.deployed();

    // We have to enable all the FixedLenders in the auditor
    await Promise.all(
      Array.from(mockedTokens.keys()).map(async (tokenName) => {
        const { decimals, collateralRate, usdPrice } =
          mockedTokens!.get(tokenName)!;
        const totalSupply = ethers.utils.parseUnits("100000000000", decimals);
        let underlyingToken: Contract;
        if (tokenName === "WETH") {
          const Weth = await ethers.getContractFactory("WETH9");
          underlyingToken = await Weth.deploy();
          await underlyingToken.deployed();
          await underlyingToken.deposit({ value: totalSupply });
        } else {
          const MockedToken = await ethers.getContractFactory("MockedToken");
          underlyingToken = await MockedToken.deploy(
            "Fake " + tokenName,
            "F" + tokenName,
            decimals,
            totalSupply.toString()
          );
          await underlyingToken.deployed();
        }
        const MockedEToken = await ethers.getContractFactory("EToken");
        const eToken = await MockedEToken.deploy(
          "eFake " + tokenName,
          "eF" + tokenName,
          decimals
        );
        await eToken.deployed();

        const PoolAccounting = await ethers.getContractFactory(
          "PoolAccounting",
          {
            libraries: {
              TSUtils: tsUtils.address,
              PoolLib: poolLib.address,
            },
          }
        );
        const poolAccounting = await PoolAccounting.deploy(
          interestRateModel.address
        );

        const FixedLender = await ethers.getContractFactory(
          tokenName === "WETH" ? "ETHFixedLender" : "FixedLender"
        );
        const fixedLender = await FixedLender.deploy(
          underlyingToken.address,
          tokenName,
          eToken.address,
          auditor.address,
          poolAccounting.address
        );
        await fixedLender.deployed();

        await poolAccounting.initialize(fixedLender.address);
        await eToken.initialize(fixedLender.address, auditor.address);

        // Mock PriceOracle setting dummy price
        await oracle.setPrice(tokenName, usdPrice);
        // Enable Market for FixedLender-TOKEN by setting the collateral rates
        await auditor.enableMarket(
          fixedLender.address,
          collateralRate,
          tokenName,
          tokenName,
          decimals
        );

        // Handy maps with all the fixedLenders and underlying tokens
        fixedLenderContracts.set(tokenName, fixedLender);
        poolAccountingContracts.set(tokenName, poolAccounting);
        underlyingContracts.set(tokenName, underlyingToken);
        eTokenContracts.set(tokenName, eToken);
      })
    );

    const [owner] = await ethers.getSigners();

    return new DefaultEnv(
      oracle,
      auditor,
      interestRateModel,
      tsUtils,
      poolLib,
      marketsLib,
      fixedLenderContracts,
      poolAccountingContracts,
      underlyingContracts,
      eTokenContracts,
      mockedTokens!,
      owner
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
    await asset
      .connect(this.currentWallet)
      .approve(fixedLender.address, amount);
    return fixedLender.connect(this.currentWallet).depositToSmartPool(amount);
  }

  public async depositMP(
    assetString: string,
    maturityPool: number,
    units: string,
    expectedAtMaturity?: string
  ) {
    const asset = this.getUnderlying(assetString);
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    const expectedAmount =
      (expectedAtMaturity &&
        parseUnits(expectedAtMaturity, this.digitsForAsset(assetString))) ||
      applyMinFee(amount);
    await asset
      .connect(this.currentWallet)
      .approve(fixedLender.address, amount);
    return fixedLender
      .connect(this.currentWallet)
      .depositToMaturityPool(amount, maturityPool, expectedAmount);
  }

  public async depositMPETH(
    assetString: string,
    maturityPool: number,
    units: string,
    expectedAtMaturity?: string
  ) {
    assert(assetString === "WETH");
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    const expectedAmount =
      (expectedAtMaturity &&
        parseUnits(expectedAtMaturity, this.digitsForAsset(assetString))) ||
      applyMinFee(amount);
    return fixedLender
      .connect(this.currentWallet)
      .depositToMaturityPoolEth(maturityPool, expectedAmount, {
        value: amount,
      });
  }

  public async depositSPETH(assetString: string, units: string) {
    assert(assetString === "WETH");
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    return fixedLender
      .connect(this.currentWallet)
      .depositToSmartPoolEth({ value: amount });
  }

  public async withdrawSP(assetString: string, units: string) {
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    return fixedLender
      .connect(this.currentWallet)
      .withdrawFromSmartPool(amount);
  }

  public async withdrawSPETH(assetString: string, units: string) {
    assert(assetString === "WETH");
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    return fixedLender
      .connect(this.currentWallet)
      .withdrawFromSmartPoolEth(amount);
  }

  public async withdrawMPETH(
    assetString: string,
    maturityPool: number,
    units: string
  ) {
    assert(assetString === "WETH");
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    return fixedLender
      .connect(this.currentWallet)
      .withdrawFromMaturityPoolEth(
        this.currentWallet.address,
        amount,
        maturityPool
      );
  }

  public async withdrawMP(
    assetString: string,
    maturityPool: number,
    units: string
  ) {
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    return fixedLender
      .connect(this.currentWallet)
      .withdrawFromMaturityPool(
        this.currentWallet.address,
        amount,
        maturityPool
      );
  }

  public async borrowMP(
    assetString: string,
    maturityPool: number,
    units: string,
    expectedAtMaturity?: string
  ) {
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: BigNumber;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(
        expectedAtMaturity,
        this.digitsForAsset(assetString)
      );
    } else {
      expectedAmount = applyMaxFee(amount);
    }
    return fixedLender
      .connect(this.currentWallet)
      .borrowFromMaturityPool(amount, maturityPool, expectedAmount);
  }

  public async borrowMPETH(
    assetString: string,
    maturityPool: number,
    units: string,
    expectedAtMaturity?: string
  ) {
    assert(assetString === "WETH");
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    let expectedAmount: BigNumber;
    if (expectedAtMaturity) {
      expectedAmount = parseUnits(
        expectedAtMaturity,
        this.digitsForAsset(assetString)
      );
    } else {
      expectedAmount = applyMaxFee(amount);
    }
    return fixedLender
      .connect(this.currentWallet)
      .borrowFromMaturityPoolEth(maturityPool, expectedAmount, {
        value: amount,
      });
  }

  public async repayMP(
    assetString: string,
    maturityPool: number,
    units: string
  ) {
    const asset = this.getUnderlying(assetString);
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    await asset
      .connect(this.currentWallet)
      .approve(fixedLender.address, amount);
    return fixedLender
      .connect(this.currentWallet)
      .repayToMaturityPool(this.currentWallet.address, maturityPool, amount);
  }

  public async repayMPETH(
    assetString: string,
    maturityPool: number,
    units: string
  ) {
    assert(assetString === "WETH");
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    return fixedLender
      .connect(this.currentWallet)
      .repayToMaturityPoolEth(this.currentWallet.address, maturityPool, {
        value: amount,
      });
  }

  public async enterMarkets(assets: string[]) {
    const markets = assets.map((asset) => this.getFixedLender(asset).address);
    return this.auditor.connect(this.currentWallet).enterMarkets(markets);
  }

  public async setBorrowRate(rate: string) {
    await this.interestRateModel
      .connect(this.currentWallet)
      .setBorrowRate(parseUnits(rate));
  }

  public async transfer(
    assetString: string,
    wallet: SignerWithAddress,
    units: string
  ) {
    await this.getUnderlying(assetString)
      .connect(this.currentWallet)
      .transfer(
        wallet.address,
        parseUnits(units, this.digitsForAsset(assetString))
      );
  }

  public digitsForAsset(assetString: string) {
    return this.mockedTokens.get(assetString)!.decimals;
  }

  public async enableMarket(
    fixedLender: string,
    collateralFactor: BigNumber,
    symbol: string,
    tokenName: string,
    decimals: number
  ) {
    return this.auditor
      .connect(this.currentWallet)
      .enableMarket(fixedLender, collateralFactor, symbol, tokenName, decimals);
  }

  public async setLiquidationIncentive(incentive: string) {
    return this.auditor
      .connect(this.currentWallet)
      .setLiquidationIncentive(parseUnits(incentive));
  }

  public async smartPoolBorrowed(asset: string) {
    return this.getFixedLender(asset).smartPoolBorrowed();
  }

  public async setBorrowCaps(assets: string[], borrowCaps: string[]) {
    assert(assets.length == borrowCaps.length);

    const markets = assets.map((asset) => this.getFixedLender(asset).address);
    const borrowCapsBigNumber = borrowCaps.map((cap, index) =>
      parseUnits(cap, this.digitsForAsset(assets[index]))
    );

    return this.auditor
      .connect(this.currentWallet)
      .setMarketBorrowCaps(markets, borrowCapsBigNumber);
  }

  public async setExaSpeed(asset: string, speed: string) {
    return this.auditor
      .connect(this.currentWallet)
      .setExaSpeed(this.getFixedLender(asset).address, parseUnits(speed));
  }

  public async deployDuplicatedAuditor() {
    const Auditor = await ethers.getContractFactory("Auditor", {
      libraries: {
        TSUtils: this.tsUtils.address,
        MarketsLib: this.marketsLib.address,
      },
    });

    let newAuditor = await Auditor.deploy(this.oracle.address);
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
    underlyingTokenName: string
  ) {
    const PoolAccounting = await ethers.getContractFactory("PoolAccounting", {
      libraries: {
        TSUtils: this.tsUtils.address,
        PoolLib: this.poolLib.address,
      },
    });
    const poolAccounting = await PoolAccounting.deploy(
      interestRateModelAddress
    );
    const FixedLender = await ethers.getContractFactory("FixedLender");
    const fixedLender = await FixedLender.deploy(
      underlyingAddress,
      underlyingTokenName,
      eTokenAddress,
      newAuditorAddress,
      poolAccounting.address
    );

    await fixedLender.deployed();
    return fixedLender;
  }

  public async smartPoolState(assetString: string) {
    const poolLender = this.getPoolAccounting(assetString);
    const eToken = this.getEToken(assetString);
    return new SmartPoolState(
      await eToken.totalSupply(),
      await poolLender.smartPoolBorrowed()
    );
  }

  public async maturityPool(assetString: string, maturityPoolID: number) {
    const poolLender = this.getPoolAccounting(assetString);
    return poolLender.maturityPools(maturityPoolID);
  }

  public async accountSnapshot(assetString: string, maturityPoolID: number) {
    const fixedLender = this.getFixedLender(assetString);
    return fixedLender.getAccountSnapshot(
      this.currentWallet.address,
      maturityPoolID
    );
  }

  public async treasury(assetString: string) {
    const fixedLender = this.getFixedLender(assetString);
    return fixedLender.treasury();
  }

  /* Replicates PoolAccounting.sol calculation of debt penalties per second when a user is delayed and did not repay before maturity (getAccountDebt) */
  public calculatePenaltiesForDebt(
    debt: number,
    secondsDelayed: number,
    penaltyRate: number
  ): number {
    return secondsDelayed > 0 ? debt * (secondsDelayed * penaltyRate) : 0;
  }
}
