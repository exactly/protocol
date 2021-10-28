import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract, BigNumber } from "ethers";
import {
  errorGeneric,
  errorUnmatchedPool,
  ExactlyEnv,
  ExaTime,
  parseBorrowEvent,
  parseSupplyEvent,
  PoolState,
  ProtocolError,
} from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

Error.stackTraceLimit = Infinity;

describe("Exafin", function () {
  let exactlyEnv: ExactlyEnv;

  let underlyingToken: Contract;
  let exafin: Contract;
  let auditor: Contract;

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
  let exaTime: ExaTime = new ExaTime();

  let snapshot: any;

  beforeEach(async () => {
    [owner, mariaUser, johnUser] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(tokensUSDPrice, tokensCollateralRate);

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    exafin = exactlyEnv.getExafin("DAI");
    auditor = exactlyEnv.auditor;

    // From Owner to User
    await underlyingToken.transfer(mariaUser.address, parseUnits("10"));

    // 1 EXA per block as rewards
    await auditor.setExaSpeed(exactlyEnv.getExafin("DAI").address, parseUnits("1"))

    // This can be optimized (so we only do it once per file, not per test)
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  it("We get rewards for supply", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(exafin.address, underlyingAmount);
    await exafin.supply(owner.address, underlyingAmount, exaTime.nextPoolID());
    await underlyingToken.approve(exafin.address, underlyingAmount);
    await exafin.supply(owner.address, underlyingAmount, exaTime.nextPoolID());
  });


  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
