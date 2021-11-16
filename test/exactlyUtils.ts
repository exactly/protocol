import { ethers } from "hardhat";
import {
  Contract,
  BigNumber,
  ContractTransaction,
  ContractReceipt,
} from "ethers";
import { parseUnits } from "ethers/lib/utils";

export interface BorrowEventInterface {
  to: string;
  amount: BigNumber;
  commission: BigNumber;
  maturityDate: BigNumber;
}

export interface SuppliedEventInterface {
  from: string;
  amount: BigNumber;
  commission: BigNumber;
  maturityDate: BigNumber;
}

export async function parseBorrowEvent(tx: ContractTransaction) {
  let receipt: ContractReceipt = await tx.wait();
  return new Promise<BorrowEventInterface>((resolve, reject) => {
    let args = receipt.events?.filter((x) => {
      return x.event == "Borrowed";
    })[0]["args"];

    if (args != undefined) {
      resolve({
        to: args.to.toString(),
        amount: BigNumber.from(args.amount),
        commission: BigNumber.from(args.commission),
        maturityDate: BigNumber.from(args.maturityDate),
      });
    } else {
      reject(new Error("Event not found"));
    }
  });
}

export async function parseSupplyEvent(tx: ContractTransaction) {
  let receipt: ContractReceipt = await tx.wait();
  return new Promise<SuppliedEventInterface>((resolve, reject) => {
    let args = receipt.events?.filter((x) => {
      return x.event == "Supplied";
    })[0]["args"];

    if (args != undefined) {
      resolve({
        from: args.from.toString(),
        amount: BigNumber.from(args.amount),
        commission: BigNumber.from(args.commission),
        maturityDate: BigNumber.from(args.maturityDate),
      });
    } else {
      reject(new Error("Event not found"));
    }
  });
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
  NOT_AN_EXAFIN_SENDER,
  INVALID_SET_BORROW_CAP,
  MARKET_BORROW_CAP_REACHED,
  INCONSISTENT_PARAMS_LENGTH,
  REDEEM_CANT_BE_ZERO,
  EXIT_MARKET_BALANCE_OWED,
}

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
  exafinContracts: Map<string, Contract>;
  underlyingContracts: Map<string, Contract>;
  baseRate: BigNumber;
  marginRate: BigNumber;
  slopeRate: BigNumber;
  notAnExafinAddress = "0x6D88564b707518209a4Bea1a57dDcC23b59036a8";
  usdAddress: string;

  constructor(
    _oracle: Contract,
    _auditor: Contract,
    _interestRateModel: Contract,
    _tsUtils: Contract,
    _exaLib: Contract,
    _marketsLib: Contract,
    _exaToken: Contract,
    _exafinContracts: Map<string, Contract>,
    _underlyingContracts: Map<string, Contract>
  ) {
    this.oracle = _oracle;
    this.auditor = _auditor;
    this.exafinContracts = _exafinContracts;
    this.underlyingContracts = _underlyingContracts;
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

  public getExafin(key: string): Contract {
    return this.exafinContracts.get(key)!;
  }

  public getUnderlying(key: string): Contract {
    return this.underlyingContracts.get(key)!;
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
  exafinHarness: Contract;
  notAnExafinAddress = "0x6D88564b707518209a4Bea1a57dDcC23b59036a8";

  constructor(
    _auditorHarness: Contract,
    _exaLib: Contract,
    _exaToken: Contract,
    _exafinHarness: Contract
  ) {
    this.auditorHarness = _auditorHarness;
    this.exaLib = _exaLib;
    this.exaToken = _exaToken;
    this.exafinHarness = _exafinHarness;
  }
}

export class ExactlyEnv {
  static async create(
    mockedTokens: Map<string, MockedTokenSpec>
  ): Promise<DefaultEnv> {
    let exafinContracts = new Map<string, Contract>();
    let underlyingContracts = new Map<string, Contract>();

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

    const InterestRateModel = await ethers.getContractFactory(
      "InterestRateModel",
      {
        libraries: {
          TSUtils: tsUtils.address,
        },
      }
    );

    let interestRateModel = await InterestRateModel.deploy(
      parseUnits("0.01"),
      parseUnits("0.07"),
      parseUnits("0.07"),
      parseUnits("0.02")
    );
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

    // We have to enable all the Exafins in the auditor
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

        const Exafin = await ethers.getContractFactory("Exafin", {
          libraries: {
            TSUtils: tsUtils.address,
          },
        });
        const exafin = await Exafin.deploy(
          underlyingToken.address,
          tokenName,
          auditor.address,
          interestRateModel.address
        );
        await exafin.deployed();

        // Mock PriceOracle setting dummy price
        await oracle.setPrice(tokenName, usdPrice);
        // Enable Market for Exafin-TOKEN by setting the collateral rates
        await auditor.enableMarket(
          exafin.address,
          collateralRate,
          tokenName,
          tokenName,
          decimals
        );

        // Handy maps with all the exafins and underlying tokens
        exafinContracts.set(tokenName, exafin);
        underlyingContracts.set(tokenName, underlyingToken);
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
          exafinContracts,
          underlyingContracts
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

    const ExafinHarness = await ethers.getContractFactory("ExafinHarness");
    let exafinHarness = await ExafinHarness.deploy();
    await exafinHarness.deployed();

    const AuditorHarness = await ethers.getContractFactory("AuditorHarness", {
      libraries: {
        ExaLib: exaLib.address,
      },
    });
    let auditorHarness = await AuditorHarness.deploy(exaToken.address);
    await auditorHarness.deployed();
    await auditorHarness.enableMarket(exafinHarness.address);

    return new Promise<RewardsLibEnv>((resolve) => {
      resolve(
        new RewardsLibEnv(auditorHarness, exaLib, exaToken, exafinHarness)
      );
    });
  }
}

export class ExaTime {
  timestamp: number;
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
