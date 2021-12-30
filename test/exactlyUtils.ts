import { ethers } from "hardhat";
import { Contract, BigNumber } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { DefaultEnv, MockedTokenSpec } from "./defaultEnv";

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
  NONE,
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
  NOT_A_FIXED_LENDER_SENDER,
  INVALID_SET_BORROW_CAP,
  MARKET_BORROW_CAP_REACHED,
  INCONSISTENT_PARAMS_LENGTH,
  REDEEM_CANT_BE_ZERO,
  EXIT_MARKET_BALANCE_OWED,
  CALLER_MUST_BE_FIXED_LENDER,
  ETOKEN_ALREADY_INITIALIZED,
  INSUFFICIENT_PROTOCOL_LIQUIDITY,
  TOO_MUCH_SLIPPAGE,
  TOO_MUCH_REPAY_TRANSFER,
  SMART_POOL_FUNDS_LOCKED,
}

export type EnvConfig = {
  mockedTokens?: Map<string, MockedTokenSpec>;
  useRealInterestRateModel?: boolean;
};

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
const defaultMockedTokens: Map<string, MockedTokenSpec> = new Map([
  [
    "DAI",
    {
      decimals: 18,
      collateralRate: parseUnits("0.8"),
      usdPrice: parseUnits("1"),
    },
  ],
  [
    "ETH",
    {
      decimals: 18,
      collateralRate: parseUnits("0.7"),
      usdPrice: parseUnits("3000"),
    },
  ],
  [
    "WBTC",
    {
      decimals: 8,
      collateralRate: parseUnits("0.6"),
      usdPrice: parseUnits("63000"),
    },
  ],
  [
    "USDC",
    {
      decimals: 6,
      collateralRate: parseUnits("0.8"),
      usdPrice: parseUnits("1"),
    },
  ],
]);

export class ExactlyEnv {
  static async create({
    mockedTokens,
    useRealInterestRateModel,
  }: EnvConfig): Promise<DefaultEnv> {
    if (mockedTokens === undefined) {
      mockedTokens = defaultMockedTokens;
    }
    let fixedLenderContracts = new Map<string, Contract>();
    let underlyingContracts = new Map<string, Contract>();
    let eTokenContracts = new Map<string, Contract>();

    const TSUtilsLib = await ethers.getContractFactory("TSUtils");
    let tsUtils = await TSUtilsLib.deploy();
    await tsUtils.deployed();

    const ExaLib = await ethers.getContractFactory("ExaLib");
    let exaLib = await ExaLib.deploy();
    await exaLib.deployed();

    const PoolLib = await ethers.getContractFactory("PoolLib", {
      libraries: {
        TSUtils: tsUtils.address,
      },
    });
    const poolLib = await PoolLib.deploy();
    await poolLib.deployed();

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
          mockedTokens!.get(tokenName)!;
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
            PoolLib: poolLib.address,
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
      exaLib,
      poolLib,
      marketsLib,
      exaToken,
      fixedLenderContracts,
      underlyingContracts,
      eTokenContracts,
      mockedTokens!,
      owner
    );
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

    const AuditorHarness = await ethers.getContractFactory("AuditorHarness", {
      libraries: {
        ExaLib: exaLib.address,
      },
    });
    let auditorHarness = await AuditorHarness.deploy(exaToken.address);
    await auditorHarness.deployed();
    await auditorHarness.enableMarket(fixedLenderHarness.address);
    eToken.initialize(fixedLenderHarness.address, auditorHarness.address);

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

  public day(dayNumber: number): number {
    return this.timestamp + this.ONE_DAY * dayNumber;
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

  public invalidPoolID(): number {
    return (
      this.timestamp - (this.timestamp % this.INTERVAL) + this.INTERVAL + 33
    );
  }

  public distantFuturePoolID(): number {
    return this.futurePools(12).pop()! + 86400 * 7;
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
