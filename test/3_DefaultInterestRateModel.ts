import { expect } from "chai";
import { ethers } from "hardhat";
import { formatUnits, parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { ProtocolError, ExactlyEnv, ExaTime, parseSupplyEvent, errorGeneric } from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { parseEther } from "ethers/lib/utils";

describe("DefaultInterestRateModel", () => {
  let exactlyEnv: ExactlyEnv;

  let underlyingToken: Contract;
  let eth: Contract;
  let exafin: Contract;
  let exafin2: Contract;
  let auditor: Contract;
  let interestRateModel: Contract;

  let tokensCollateralRate = new Map([
    ["DAI", parseUnits("0.8", 18)],
    ["ETH", parseUnits("0.7", 18)],
  ]);

  // Oracle price is in 10**6
  let tokensUSDPrice = new Map([
    ["DAI", parseUnits("1", 6)],
    ["ETH", parseUnits("3100", 6)],
  ]);

  let mariaUser: SignerWithAddress;
  let johnUser: SignerWithAddress;
  let owner: SignerWithAddress;
  let exaTime: ExaTime;

  let snapshot: any;
  let futurePool: number;

  let pool = {
    borrowed: 0,
    supplied: 0,
    debt: 0,
    available: 0,
  };

  let smartPool = {
    borrowed: 0,
    supplied: 0,
  };

  beforeEach(async () => {
    pool = {
      borrowed: 0,
      supplied: 0,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 0,
      supplied: 0,
    };
    [owner, mariaUser, johnUser] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(tokensUSDPrice, tokensCollateralRate);

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    eth = exactlyEnv.getUnderlying("ETH");

    exafin = exactlyEnv.getExafin("DAI");
    exafin2 = exactlyEnv.getExafin("ETH");
    auditor = exactlyEnv.auditor;
    interestRateModel = exactlyEnv.interestRateModel;
    // From Owner to User
    underlyingToken.transfer(mariaUser.address, parseUnits("1000000"));
    eth.transfer(mariaUser.address, parseEther("100"));
    exaTime = new ExaTime();

    futurePool = exaTime.futurePools(2)[1];

    // This can be optimized (so we only do it once per file, not per test)
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await ethers.provider.send("evm_snapshot", []);

    //This sets the EVM timestamp to a specific so we have real unit testing
    await ethers.provider.send("evm_setNextBlockTimestamp", [exaTime.nextPoolID()]);
    await ethers.provider.send("evm_mine", []);
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });

  it("With well funded Smart pool, supply 1 to Maturity Pool, borrow 2 from maturity pool, borrow 2 from maturity pool. Should get Maturity pool rate", async () => {
    pool = {
      borrowed: 4,
      supplied: 4,
      debt: 3,
      available: 0,
    };

    smartPool = {
      borrowed: 3,
      supplied: 100000,
    };

    expect(formatUnits(await interestRateModel.getRateToBorrow(futurePool, pool, smartPool, true))).to.be.equal(
      "0.001342465753424657"
    );
  });

  it("With well funded Smart pool, supply 10000 to Maturity Pool, borrow 10000 from maturity pool. Should get Maturity pool rate", async () => {
    pool = {
      borrowed: 10000,
      supplied: 10000,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 10000,
      supplied: 110000,
    };

    expect(formatUnits(await interestRateModel.getRateToBorrow(futurePool, pool, smartPool, true))).to.be.equal(
      "0.001342465753424657"
    );
  });

  it("With well funded Smart pool, borrow 10000 from maturity pool. Should get Maturity pool rate", async () => {
    pool = {
      borrowed: 10000,
      supplied: 10000,
      debt: 10000,
      available: 0,
    };

    smartPool = {
      borrowed: 10000,
      supplied: 100000,
    };

    expect(formatUnits(await interestRateModel.getRateToBorrow(futurePool, pool, smartPool, true))).to.be.equal(
      "0.001342465753424657"
    );
  });

  it("With well funded Smart pool, borrow 10000 from maturity pool, after that borrow 10000 again. Should get Maturity pool rate in both cases", async () => {
    pool = {
      borrowed: 10000,
      supplied: 10000,
      debt: 10000,
      available: 0,
    };

    smartPool = {
      borrowed: 10000,
      supplied: 100000,
    };

    expect(formatUnits(await interestRateModel.getRateToBorrow(futurePool, pool, smartPool, true))).to.be.equal(
      "0.001342465753424657"
    );

    pool = {
      borrowed: 20000,
      supplied: 20000,
      debt: 20000,
      available: 0,
    };

    smartPool = {
      borrowed: 20000,
      supplied: 100000,
    };

    expect(formatUnits(await interestRateModel.getRateToBorrow(futurePool, pool, smartPool, true))).to.be.equal(
      "0.001342465753424657"
    );
  });

  it("Borrow less than supplied in maturity pool", async () => {
    pool = {
      borrowed: 20,
      supplied: 10000,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 0,
      supplied: 10000,
    };

    expect(formatUnits(await interestRateModel.getRateToBorrow(futurePool, pool, smartPool, true))).to.be.equal(
      "0.000002684931506849"
    );
  });

  it("Borrow less than supplied in maturity pool, then supply some more tokens", async () => {
    pool = {
      borrowed: 10,
      supplied: 10010,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 0,
      supplied: 10000,
    };

    expect(formatUnits(await interestRateModel.getRateToSupply(10, futurePool, pool, smartPool))).to.be.equal(
      "0.000001341124628795"
    );
  });

  it("Borrow 10 from maturity pool with no money in maturity pool nor smart pool", async () => {
    pool = {
      borrowed: 10,
      supplied: 0,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 0,
      supplied: 0,
    };

    expect(formatUnits(await interestRateModel.getRateToBorrow(futurePool, pool, smartPool, true))).to.be.equal("0.0");
  });
});
