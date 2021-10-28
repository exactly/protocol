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

  beforeEach(async () => {
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

    // This can be optimized (so we only do it once per file, not per test)
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  it("Supply 1, borrow 2, borrow 2", async () => {
    const pool = {
      borrowed: 4,
      supplied: 4,
      debt: 3,
      available: 0,
    };

    const smartPool = {
      borrowed: 3,
      supplied: 100000,
    };

    console.log(
      formatUnits(await interestRateModel.getRateToBorrow(1, exaTime.futurePools(6)[1], pool, smartPool, true))
    );
  });

  it("Borrow 10000, supply 10000", async () => {
    const pool = {
      borrowed: 10000,
      supplied: 10000,
      debt: 0,
      available: 0,
    };

    const smartPool = {
      borrowed: 10000,
      supplied: 110000,
    };

    console.log(formatUnits(await interestRateModel.getRateToBorrow(1, exaTime.nextPoolID(), pool, smartPool, true)));
  });

  it("Borrow 10000", async () => {
    const pool = {
      borrowed: 10000,
      supplied: 10000,
      debt: 10000,
      available: 0,
    };

    const smartPool = {
      borrowed: 10000,
      supplied: 100000,
    };

    console.log(formatUnits(await interestRateModel.getRateToBorrow(1, exaTime.nextPoolID(), pool, smartPool, true)));
  });

  it("Borrow 10 with no money in maturity pool nor smart pool", () => {
    const pool = {
      borrowed: 10,
      supplied: 0,
      debt: 0,
      available: 0,
    };

    const smartPool = {
      borrowed: 0,
      supplied: 0,
    };

    expect(interestRateModel.getRateToBorrow(1, exaTime.nextPoolID(), pool, smartPool, true)).to.be.reverted;
  });
});
