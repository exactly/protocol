import { ethers } from "hardhat";
import { Contract, BigNumber } from "ethers";
import { parseUnits } from "ethers/lib/utils";

export interface BorrowFromMaturityPoolEventInterface {
  to: string;
  amount: BigNumber;
  commission: BigNumber;
  maturityDate: BigNumber;
}

export interface DepositToMaturityPoolEventInterface {
  from: string;
  amount: BigNumber;
  commission: BigNumber;
  maturityDate: BigNumber;
}

export function errorUnmatchedPool(
  state: PoolState,
  requiredState: PoolState
): string {
  return "UnmatchedPoolState(" + state + ", " + requiredState + ")";
}

export function errorGeneric(errorCode: ProtocolError): string {
  return "GenericError(" + errorCode + ")";
}

export function applyMaxFee(amount: BigNumber): BigNumber {
  return amount.add(amount.div(10)); // 10%
}

export function applyMinFee(amount: BigNumber): BigNumber {
  return amount; // 0%
}

export enum PoolState {
  INVALID,
  MATURED,
  VALID,
  NOT_READY,
}

export enum ProtocolError {
  NO_ERROR,
  MARKET_NOT_LISTED,
  MARKET_ALREADY_LISTED,
  SNAPSHOT_ERROR,
  PRICE_ERROR,
  INSUFFICIENT_LIQUIDITY,
  UNSUFFICIENT_SHORTFALL,
  AUDITOR_MISMATCH,
  TOO_MUCH_REPAY,
  REPAY_ZERO,
  TOKENS_MORE_THAN_BALANCE,
  INVALID_POOL_STATE,
  INVALID_POOL_ID,
  LIQUIDATOR_NOT_BORROWER,
  BORROW_PAUSED,
  NOT_A_FIXED_LENDER_SENDER,
  INVALID_SET_BORROW_CAP,
  MARKET_BORROW_CAP_REACHED,
  INCONSISTENT_PARAMS_LENGTH,
  REDEEM_CANT_BE_ZERO,
  EXIT_MARKET_BALANCE_OWED,
  CALLER_MUST_BE_FIXED_LENDER,
  FIXED_LENDER_ALREADY_SET,
  INSUFFICIENT_PROTOCOL_LIQUIDITY,
  TOO_MUCH_SLIPPAGE,
}

export type EnvConfig = {
  mockedTokens: Map<string, MockedTokenSpec>;
  useRealInterestRateModel?: boolean;
};

export type MockedTokenSpec = {
  decimals: BigNumber | number;
  collateralRate: BigNumber;
  usdPrice: BigNumber;
};

export class DefaultEnv {
  oracle: Contract;
  auditor: Contract;
  interestRateModel: Contract;
  tsUtils: Contract;
  exaLib: Contract;
  marketsLib: Contract;
  exaToken: Contract;
  fixedLenderContracts: Map<string, Contract>;
  underlyingContracts: Map<string, Contract>;
  eTokenContracts: Map<string, Contract>;
  baseRate: BigNumber;
  marginRate: BigNumber;
  slopeRate: BigNumber;
  notAnFixedLenderAddress = "0x6D88564b707518209a4Bea1a57dDcC23b59036a8";
  usdAddress: string;

  constructor(
    _oracle: Contract,
    _auditor: Contract,
    _interestRateModel: Contract,
    _tsUtils: Contract,
    _exaLib: Contract,
    _marketsLib: Contract,
    _exaToken: Contract,
    _fixedLenderContracts: Map<string, Contract>,
    _underlyingContracts: Map<string, Contract>,
    _eTokenContracts: Map<string, Contract>
  ) {
    this.oracle = _oracle;
    this.auditor = _auditor;
    this.fixedLenderContracts = _fixedLenderContracts;
    this.underlyingContracts = _underlyingContracts;
    this.eTokenContracts = _eTokenContracts;
    this.interestRateModel = _interestRateModel;
    this.tsUtils = _tsUtils;
    this.exaLib = _exaLib;
    this.marketsLib = _marketsLib;
    this.exaToken = _exaToken;
    this.baseRate = parseUnits("0.02");
    this.marginRate = parseUnits("0.01");
    this.slopeRate = parseUnits("0.07");
    this.usdAddress = "0x0000000000000000000000000000000000000348";
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
    await this.auditor.setOracle(oracleAddress);
  }

  public async setOracleMockPrice(assetSymbol: string, valueString: string) {
    await this.oracle.setPrice(assetSymbol, parseUnits(valueString, 18));
  }
}

export class RewardsLibEnv {
  auditorHarness: Contract;
  exaLib: Contract;
  exaToken: Contract;
  fixedLenderHarness: Contract;
  eToken: Contract;
  notAnFixedLenderAddress = "0x6D88564b707518209a4Bea1a57dDcC23b59036a8";

  constructor(
    _auditorHarness: Contract,
    _exaLib: Contract,
    _exaToken: Contract,
    _fixedLenderHarness: Contract,
    _eToken: Contract
  ) {
    this.auditorHarness = _auditorHarness;
    this.exaLib = _exaLib;
    this.exaToken = _exaToken;
    this.fixedLenderHarness = _fixedLenderHarness;
    this.eToken = _eToken;
  }
}

export class ExactlyEnv {
  static async create({
    mockedTokens,
    useRealInterestRateModel,
  }: EnvConfig): Promise<DefaultEnv> {
    let fixedLenderContracts = new Map<string, Contract>();
    let underlyingContracts = new Map<string, Contract>();
    let eTokenContracts = new Map<string, Contract>();

    const TSUtilsLib = await ethers.getContractFactory("TSUtils");
    let tsUtils = await TSUtilsLib.deploy();
    await tsUtils.deployed();

    const ExaLib = await ethers.getContractFactory("ExaLib");
    let exaLib = await ExaLib.deploy();
    await exaLib.deployed();

    const MarketsLib = await ethers.getContractFactory("MarketsLib", {
      libraries: {
        TSUtils: tsUtils.address,
      },
    });
    let marketsLib = await MarketsLib.deploy();
    await marketsLib.deployed();

    const ExaToken = await ethers.getContractFactory("ExaToken");
    let exaToken = await ExaToken.deploy();
    await exaToken.deployed();

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
          parseUnits("0.02") // Penalty Rate
        )
      : await MockedInterestRateModelFactory.deploy();
    await interestRateModel.deployed();

    const Auditor = await ethers.getContractFactory("Auditor", {
      libraries: {
        TSUtils: tsUtils.address,
        ExaLib: exaLib.address,
        MarketsLib: marketsLib.address,
      },
    });
    let auditor = await Auditor.deploy(oracle.address, exaToken.address);
    await auditor.deployed();

    // We have to enable all the FixedLenders in the auditor
    await Promise.all(
      Array.from(mockedTokens.keys()).map(async (tokenName) => {
        const { decimals, collateralRate, usdPrice } =
          mockedTokens.get(tokenName)!;
        const totalSupply = ethers.utils.parseUnits("100000000000", decimals);
        const MockedToken = await ethers.getContractFactory("MockedToken");
        const underlyingToken = await MockedToken.deploy(
          "Fake " + tokenName,
          "F" + tokenName,
          decimals,
          totalSupply.toString()
        );
        await underlyingToken.deployed();
        const MockedEToken = await ethers.getContractFactory("EToken");
        const eToken = await MockedEToken.deploy(
          "eFake " + tokenName,
          "eF" + tokenName,
          decimals
        );
        await eToken.deployed();

        const FixedLender = await ethers.getContractFactory("FixedLender", {
          libraries: {
            TSUtils: tsUtils.address,
          },
        });
        const fixedLender = await FixedLender.deploy(
          underlyingToken.address,
          tokenName,
          eToken.address,
          auditor.address,
          interestRateModel.address
        );
        await fixedLender.deployed();

        await eToken.setFixedLender(fixedLender.address);

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
        underlyingContracts.set(tokenName, underlyingToken);
        eTokenContracts.set(tokenName, eToken);
      })
    );

    return new Promise<DefaultEnv>((resolve) => {
      resolve(
        new DefaultEnv(
          oracle,
          auditor,
          interestRateModel,
          tsUtils,
          exaLib,
          marketsLib,
          exaToken,
          fixedLenderContracts,
          underlyingContracts,
          eTokenContracts
        )
      );
    });
  }

  static async createRewardsEnv(): Promise<RewardsLibEnv> {
    const TSUtilsLib = await ethers.getContractFactory("TSUtils");
    let tsUtils = await TSUtilsLib.deploy();
    await tsUtils.deployed();

    const ExaLib = await ethers.getContractFactory("ExaLib");
    let exaLib = await ExaLib.deploy();
    await exaLib.deployed();

    const ExaToken = await ethers.getContractFactory("ExaToken");
    let exaToken = await ExaToken.deploy();
    await exaToken.deployed();

    const EToken = await ethers.getContractFactory("EToken", {});
    let eToken = await EToken.deploy("eDAI", "eDAI", 18);
    await eToken.deployed();

    const FixedLenderHarness = await ethers.getContractFactory(
      "FixedLenderHarness"
    );
    let fixedLenderHarness = await FixedLenderHarness.deploy();
    await fixedLenderHarness.deployed();
    await fixedLenderHarness.setEToken(eToken.address);
    eToken.setFixedLender(fixedLenderHarness.address);

    const AuditorHarness = await ethers.getContractFactory("AuditorHarness", {
      libraries: {
        ExaLib: exaLib.address,
      },
    });
    let auditorHarness = await AuditorHarness.deploy(exaToken.address);
    await auditorHarness.deployed();
    await auditorHarness.enableMarket(fixedLenderHarness.address);

    return new Promise<RewardsLibEnv>((resolve) => {
      resolve(
        new RewardsLibEnv(
          auditorHarness,
          exaLib,
          exaToken,
          fixedLenderHarness,
          eToken
        )
      );
    });
  }
}

export class ExaTime {
  timestamp: number;
  ONE_HOUR: number = 3600;
  ONE_DAY: number = 86400;
  INTERVAL: number = 86400 * 7;

  constructor(timestamp: number = Math.floor(Date.now() / 1000)) {
    this.timestamp = timestamp;
  }

  public nextPoolID(): number {
    return this.timestamp - (this.timestamp % this.INTERVAL) + this.INTERVAL;
  }

  public isPoolID(): boolean {
    return this.timestamp % this.INTERVAL == 0;
  }

  public pastPoolID(): number {
    return this.timestamp - (this.timestamp % this.INTERVAL) - this.INTERVAL;
  }

  public trimmedDay(): number {
    return this.timestamp - (this.timestamp % this.ONE_DAY);
  }

  public daysDiffWith(anotherTimestamp: number): number {
    return (anotherTimestamp - this.trimmedDay()) / this.ONE_DAY;
  }

  public futurePools(maxPools: number): number[] {
    let nextPoolID = this.nextPoolID();
    var allPools: number[] = [];
    for (let i = 0; i < maxPools; i++) {
      allPools.push(nextPoolID);
      nextPoolID += this.INTERVAL;
    }
    return allPools;
  }
}
