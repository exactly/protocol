import { ethers } from "hardhat";
import { Contract, BigNumber } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { applyMaxFee, applyMinFee } from "./exactlyUtils";
import assert from "assert";

export type MockedTokenSpec = {
  decimals: BigNumber | number;
  collateralRate: BigNumber;
  usdPrice: BigNumber;
};

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
  exaLib: Contract;
  poolLib: Contract;
  marketsLib: Contract;
  exaToken: Contract;
  fixedLenderContracts: Map<string, Contract>;
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
    _exaLib: Contract,
    _poolLib: Contract,
    _marketsLib: Contract,
    _exaToken: Contract,
    _fixedLenderContracts: Map<string, Contract>,
    _underlyingContracts: Map<string, Contract>,
    _eTokenContracts: Map<string, Contract>,
    _mockedTokens: Map<string, MockedTokenSpec>,
    _currentWallet: SignerWithAddress
  ) {
    this.oracle = _oracle;
    this.auditor = _auditor;
    this.fixedLenderContracts = _fixedLenderContracts;
    this.underlyingContracts = _underlyingContracts;
    this.eTokenContracts = _eTokenContracts;
    this.interestRateModel = _interestRateModel;
    this.tsUtils = _tsUtils;
    this.exaLib = _exaLib;
    this.poolLib = _poolLib;
    this.mockedTokens = _mockedTokens;
    this.marketsLib = _marketsLib;
    this.exaToken = _exaToken;
    this.baseRate = parseUnits("0.02");
    this.marginRate = parseUnits("0.01");
    this.slopeRate = parseUnits("0.07");
    this.usdAddress = "0x0000000000000000000000000000000000000348";
    this.currentWallet = _currentWallet;
  }

  public getFixedLender(key: string): Contract {
    return this.fixedLenderContracts.get(key)!;
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

  public async withdrawSP(assetString: string, units: string) {
    const fixedLender = this.getFixedLender(assetString);
    const amount = parseUnits(units, this.digitsForAsset(assetString));
    return fixedLender
      .connect(this.currentWallet)
      .withdrawFromSmartPool(amount);
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

  public async claimAllEXA(addressToSend: string) {
    return this.auditor.connect(this.currentWallet).claimExaAll(addressToSend);
  }

  public async deployDuplicatedAuditor() {
    const Auditor = await ethers.getContractFactory("Auditor", {
      libraries: {
        TSUtils: this.tsUtils.address,
        ExaLib: this.exaLib.address,
        MarketsLib: this.marketsLib.address,
      },
    });

    let newAuditor = await Auditor.deploy(
      this.oracle.address,
      this.exaToken.address
    );
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
    const FixedLender = await ethers.getContractFactory("FixedLender", {
      libraries: {
        TSUtils: this.tsUtils.address,
        PoolLib: this.poolLib.address,
      },
    });

    const fixedLender = await FixedLender.deploy(
      underlyingAddress,
      underlyingTokenName,
      eTokenAddress,
      newAuditorAddress,
      interestRateModelAddress
    );

    await fixedLender.deployed();
    return fixedLender;
  }

  public async smartPoolState(assetString: string) {
    const fixedLender = this.getFixedLender(assetString);
    const eToken = this.getEToken(assetString);
    return new SmartPoolState(
      await eToken.totalSupply(),
      await fixedLender.smartPoolBorrowed()
    );
  }
}
