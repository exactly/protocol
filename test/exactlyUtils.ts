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

export class ExactlyEnv {
  oracle: Contract;
  auditor: Contract;
  exafinContracts: Map<string, Contract>;
  underlyingContracts: Map<string, Contract>;
  baseRate: BigNumber;
  marginRate: BigNumber;
  slopeRate: BigNumber;

  constructor(
    _oracle: Contract,
    _auditor: Contract,
    _exafinContracts: Map<string, Contract>,
    _underlyingContracts: Map<string, Contract>
  ) {
    this.oracle = _oracle;
    this.auditor = _auditor;
    this.exafinContracts = _exafinContracts;
    this.underlyingContracts = _underlyingContracts;
    this.baseRate = parseUnits("0.02");
    this.marginRate = parseUnits("0.01");
    this.slopeRate = parseUnits("0.07");
  }

  public getExafin(key: string): Contract {
    return this.exafinContracts.get(key)!;
  }

  public getUnderlying(key: string): Contract {
    return this.underlyingContracts.get(key)!;
  }

  static async create(
    tokensUSDPrice: Map<string, BigNumber>,
    tokensCollateralRate: Map<string, BigNumber>
  ): Promise<ExactlyEnv> {
    let exafinContracts = new Map<string, Contract>();
    let underlyingContracts = new Map<string, Contract>();

    const SomeOracle = await ethers.getContractFactory("SomeOracle");
    let oracle = await SomeOracle.deploy();
    await oracle.deployed();

    const Auditor = await ethers.getContractFactory("Auditor");
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

        const Exafin = await ethers.getContractFactory("Exafin");
        const exafin = await Exafin.deploy(
          underlyingToken.address,
          tokenName,
          auditor.address
        );
        await exafin.deployed();
        await exafin.transferOwnership(auditor.address);

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
        new ExactlyEnv(oracle, auditor, exafinContracts, underlyingContracts)
      );
    });
  }
}

export class ExaTime {
  timestamp: number;

  private oneDay: number = 86400;
  private thirtyDays: number = 86400 * 30;

  constructor(timestamp: number = Math.floor(Date.now() / 1000)) {
    this.timestamp = timestamp;
  }

  public nextPoolID(): ExaTime {
    return new ExaTime(
      this.timestamp - (this.timestamp % this.thirtyDays) + this.thirtyDays
    );
  }

  public trimmedDay(): ExaTime {
    return new ExaTime(this.timestamp - (this.timestamp % this.oneDay));
  }

  public daysDiffWith(anotherTimestamp: number): number {
    return (anotherTimestamp - this.trimmedDay().timestamp) / this.oneDay;
  }
}
