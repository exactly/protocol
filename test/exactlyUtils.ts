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

export function parseBorrowEvent(tx: ContractTransaction) {
  return new Promise<BorrowEventInterface>(async (resolve, reject) => {
    let receipt: ContractReceipt = await tx.wait();
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

export function parseSupplyEvent(tx: ContractTransaction) {
  return new Promise<SuppliedEventInterface>(async (resolve, reject) => {
    let receipt: ContractReceipt = await tx.wait();
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

export function errorUnmatchedPool(state: PoolState, requiredState: PoolState): string {
  return "UnmatchedPoolState("+ state + ", " + requiredState + ")";
}

export function errorGeneric(errorCode: ProtocolError): string {
  return "GenericError("+ errorCode + ")";
}

export enum PoolState {
  INVALID,
  MATURED,
  VALID,
  NOT_READY
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
  INCONSISTENT_PARAMS_LENGTH
}

export class ExactlyEnv {

  oracle: Contract;
  auditor: Contract;
  interestRateModel: Contract;
  tsUtils: Contract;
  exafinContracts: Map<string, Contract>;
  underlyingContracts: Map<string, Contract>;
  baseRate: BigNumber;
  marginRate: BigNumber;
  slopeRate: BigNumber;
  usdAddress: string;

  constructor(
    _oracle: Contract,
    _auditor: Contract,
    _interestRateModel: Contract,
    _tsUtils: Contract,
    _exafinContracts: Map<string, Contract>,
    _underlyingContracts: Map<string, Contract>
  ) {
    this.oracle = _oracle;
    this.auditor = _auditor;
    this.exafinContracts = _exafinContracts;
    this.underlyingContracts = _underlyingContracts;
    this.interestRateModel = _interestRateModel;
    this.tsUtils = _tsUtils;
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
    await this.oracle.setPrice(assetSymbol, parseUnits(valueString, 8));
  }

  static async create(
    tokensUSDPrice: Map<string, BigNumber>,
    tokensCollateralRate: Map<string, BigNumber>
  ): Promise<ExactlyEnv> {
    let exafinContracts = new Map<string, Contract>();
    let underlyingContracts = new Map<string, Contract>();

    const TSUtilsLib = await ethers.getContractFactory("TSUtils");
    let tsUtils = await TSUtilsLib.deploy();
    await tsUtils.deployed();

    const SomeOracle = await ethers.getContractFactory("SomeOracle");
    let oracle = await SomeOracle.deploy();
    await oracle.deployed();

    const DefaultInterestRateModel = await ethers.getContractFactory("DefaultInterestRateModel", {
      libraries: {
        TSUtils: tsUtils.address
      }
    });
    let interestRateModel = await DefaultInterestRateModel.deploy(
      parseUnits("0.01"),
      parseUnits("0.07")
    );
    await interestRateModel.deployed();

    const Auditor = await ethers.getContractFactory("Auditor", {
      libraries: {
        TSUtils: tsUtils.address
      }
    });
    let auditor = await Auditor.deploy(oracle.address);
    await auditor.deployed();

    // We have to enable all the Exafins in the auditor 
    await Promise.all(
      Array.from(tokensCollateralRate.keys()).map(async (tokenName) => {
        const totalSupply = ethers.utils.parseUnits("100000000000", 18);
        const SomeToken = await ethers.getContractFactory("SomeToken");
        const underlyingToken = await SomeToken.deploy(
          "Fake " + tokenName,
          "F" + tokenName,
          totalSupply.toString()
        );
        await underlyingToken.deployed();

        const Exafin = await ethers.getContractFactory("Exafin", {
          libraries: {
            TSUtils: tsUtils.address
          }
        });
        const exafin = await Exafin.deploy(
          underlyingToken.address,
          tokenName,
          auditor.address,
          interestRateModel.address
        );
        await exafin.deployed();

        // Mock PriceOracle setting dummy price
        await oracle.setPrice(tokenName, tokensUSDPrice.get(tokenName));
        // Enable Market for Exafin-TOKEN by setting the collateral rates
        await auditor.enableMarket(
          exafin.address,
          tokensCollateralRate.get(tokenName),
          tokenName,
          tokenName
        );

        // Handy maps with all the exafins and underlying tokens
        exafinContracts.set(tokenName, exafin);
        underlyingContracts.set(tokenName, underlyingToken);
      })
    );

    return new Promise<ExactlyEnv>((resolve) => {
      resolve(
        new ExactlyEnv(oracle, auditor, interestRateModel, tsUtils, exafinContracts, underlyingContracts)
      );
    });
  }
}

export class ExaTime {
  timestamp: number;

  private oneDay: number = 86400;
  private twoWeeks: number = 86400 * 14;

  constructor(timestamp: number = Math.floor(Date.now() / 1000)) {
    this.timestamp = timestamp;
  }

  public nextPoolID(): number {
    return (
      this.timestamp - (this.timestamp % this.twoWeeks) + this.twoWeeks
    );
  }

  public isPoolID(): boolean {
    return (
      (this.timestamp % this.twoWeeks) == 0
    );
  }

  public pastPoolID(): number {
    return (
      this.timestamp - (this.timestamp % this.twoWeeks) - this.twoWeeks
    );
  }

  public trimmedDay(): number {
    return (this.timestamp - (this.timestamp % this.oneDay));
  }

  public daysDiffWith(anotherTimestamp: number): number {
    return (anotherTimestamp - this.trimmedDay()) / this.oneDay;
  }

  public futurePools(maxPools: number): number[] {
    let nextPoolID = this.nextPoolID();
    var allPools: number[] = [];
    for (let i = 0; i < maxPools; i++) {
      allPools.push(nextPoolID);
      nextPoolID += this.twoWeeks;
    }
    return allPools;
  }
}
