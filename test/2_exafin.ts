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
  let exaTime: ExaTime;

  let snapshot: any;

  beforeEach(async () => {
    [owner, mariaUser, johnUser] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(tokensUSDPrice, tokensCollateralRate);

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    exafin = exactlyEnv.getExafin("DAI");
    auditor = exactlyEnv.auditor;

    // From Owner to User
    underlyingToken.transfer(mariaUser.address, parseUnits("10"));

    exaTime = new ExaTime();

    // This can be optimized (so we only do it once per file, not per test)
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  it("GetAccountSnapshot fails on an invalid pool", async () => {
    let invalidPoolID = exaTime.nextPoolID() + 3;
    await expect(exafin.getAccountSnapshot(owner.address, invalidPoolID)).to.be.revertedWith(
      errorGeneric(ProtocolError.INVALID_POOL_ID)
    );
  });

  it("GetTotalBorrows fails on an invalid pool", async () => {
    let invalidPoolID = exaTime.nextPoolID() + 3;
    await expect(exafin.getTotalBorrows(invalidPoolID)).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("it allows to give money to a pool", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(exafin.address, underlyingAmount);

    let tx = await exafin.supply(owner.address, underlyingAmount, exaTime.nextPoolID());
    let event = await parseSupplyEvent(tx);

    expect(event.from).to.equal(owner.address);
    expect(event.amount).to.equal(underlyingAmount);
    expect(event.maturityDate).to.equal(exaTime.nextPoolID());

    expect(await underlyingToken.balanceOf(exafin.address)).to.equal(underlyingAmount);

    expect((await exafin.getAccountSnapshot(owner.address, exaTime.nextPoolID()))[0]).to.be.equal(underlyingAmount);
  });

  it("it doesn't allow you to give money to a pool that matured", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(exafin.address, underlyingAmount);

    await expect(exafin.supply(owner.address, underlyingAmount, exaTime.pastPoolID())).to.be.revertedWith(
      errorUnmatchedPool(PoolState.MATURED, PoolState.VALID)
    );
  });

  it("it doesn't allow you to give money to a pool that hasn't been enabled yet", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(exafin.address, underlyingAmount);
    const notYetEnabledPoolID = exaTime.futurePools(12).pop()! + 86400 * 14; // two weeks after the last pool

    await expect(exafin.supply(owner.address, underlyingAmount, notYetEnabledPoolID)).to.be.revertedWith(
      errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID)
    );
  });

  it("it doesn't allow you to give money to a pool that is invalid", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(exafin.address, underlyingAmount);
    const invalidPoolID = exaTime.pastPoolID() + 666;
    await expect(exafin.supply(owner.address, underlyingAmount, invalidPoolID)).to.be.revertedWith(
      errorGeneric(ProtocolError.INVALID_POOL_ID)
    );
  });

  it("it allows you to borrow money", async () => {
    let exafinMaria = exafin.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(exafin.address, parseUnits("1"));
    await exafinMaria.supply(mariaUser.address, parseUnits("1"), exaTime.nextPoolID());
    await auditorUser.enterMarkets([exafinMaria.address]);
    expect(await exafinMaria.borrow(parseUnits("0.8"), exaTime.nextPoolID())).to.emit(exafinMaria, "Borrowed");

    expect(await exafinMaria.getTotalBorrows(exaTime.nextPoolID())).to.equal(parseUnits("0.8"));
  });

  it("it doesn't allow you to borrow money from a pool that matured", async () => {
    let exafinMaria = exafin.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(exafin.address, parseUnits("1"));
    await exafinMaria.supply(mariaUser.address, parseUnits("1"), exaTime.nextPoolID());
    await auditorUser.enterMarkets([exafinMaria.address]);
    await expect(exafinMaria.borrow(parseUnits("0.8"), exaTime.pastPoolID())).to.be.revertedWith(
      errorUnmatchedPool(PoolState.MATURED, PoolState.VALID)
    );
  });

  it("it doesn't allow you to borrow money from a pool that hasn't been enabled yet", async () => {
    let exafinMaria = exafin.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);
    let notYetEnabledPoolID = exaTime.futurePools(12).pop()! + 86400 * 14; // two weeks after the last pool
    await underlyingTokenUser.approve(exafin.address, parseUnits("1"));
    await exafinMaria.supply(mariaUser.address, parseUnits("1"), exaTime.nextPoolID());
    await auditorUser.enterMarkets([exafinMaria.address]);
    await expect(exafinMaria.borrow(parseUnits("0.8"), notYetEnabledPoolID)).to.be.revertedWith(
      errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID)
    );
  });

  it("it doesn't allow you to borrow money from a pool that is invalid", async () => {
    let exafinMaria = exafin.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);
    const invalidPoolID = exaTime.pastPoolID() + 666;

    await underlyingTokenUser.approve(exafin.address, parseUnits("1"));
    await exafinMaria.supply(mariaUser.address, parseUnits("1"), exaTime.nextPoolID());
    await auditorUser.enterMarkets([exafinMaria.address]);
    await expect(exafinMaria.borrow(parseUnits("0.8"), invalidPoolID)).to.be.revertedWith(
      errorGeneric(ProtocolError.INVALID_POOL_ID)
    );
  });

  it("Check if requirePoolState returns INVALID", async () => {
    let auditorUser = auditor.connect(mariaUser);
    const invalidPoolID = exaTime.pastPoolID() + 666;

    await expect(auditorUser.requirePoolState(invalidPoolID, PoolState.VALID)).to.be.revertedWith(
      errorUnmatchedPool(PoolState.INVALID, PoolState.VALID)
    );
  });

  it("it doesnt allow mariaUser to borrow money because not collateralized enough", async () => {
    let exafinMaria = exafin.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(exafin.address, parseUnits("1"));
    await exafinMaria.supply(mariaUser.address, parseUnits("1"), exaTime.nextPoolID());
    await auditorUser.enterMarkets([exafinMaria.address]);
    await expect(exafinMaria.borrow(parseUnits("0.9"), exaTime.nextPoolID())).to.be.reverted;
  });

  it("it allows the mariaUser to withdraw money only after maturity", async () => {
    // give the protocol some solvency
    await underlyingToken.transfer(exafin.address, parseUnits("100"));
    let originalAmount = await underlyingToken.balanceOf(mariaUser.address);

    // connect through Maria
    let exafinMaria = exafin.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    // supply some money and parse event
    await underlyingTokenUser.approve(exafin.address, parseUnits("1"));
    let tx = await exafinMaria.supply(mariaUser.address, parseUnits("1"), exaTime.nextPoolID());
    let supplyEvent = await parseSupplyEvent(tx);

    // try to redeem before maturity
    await expect(
      exafinMaria.redeem(mariaUser.address, supplyEvent.amount.add(supplyEvent.commission), exaTime.nextPoolID())
    ).to.be.revertedWith(errorUnmatchedPool(PoolState.VALID, PoolState.MATURED));

    // Move in time to maturity
    await ethers.provider.send("evm_setNextBlockTimestamp", [exaTime.nextPoolID()]);
    await ethers.provider.send("evm_mine", []);

    // finally redeem voucher and we expect maria to have her original amount + the comission earned
    await exafinMaria.redeem(mariaUser.address, supplyEvent.amount.add(supplyEvent.commission), exaTime.nextPoolID());
    expect(await underlyingToken.balanceOf(mariaUser.address)).to.be.equal(originalAmount.add(supplyEvent.commission));
  });

  it("it allows the mariaUser to repay her debt only after maturity", async () => {
    // give the protocol some solvency
    await underlyingToken.transfer(exafin.address, parseUnits("100"));

    // connect through Maria
    let originalAmount = await underlyingToken.balanceOf(mariaUser.address);
    let exafinMaria = exafin.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    // supply some money and parse event
    await underlyingTokenUser.approve(exafin.address, parseUnits("5.0"));
    let txSupply = await exafinMaria.supply(mariaUser.address, parseUnits("1"), exaTime.nextPoolID());
    let supplyEvent = await parseSupplyEvent(txSupply);
    let tx = await exafinMaria.borrow(parseUnits("0.8"), exaTime.nextPoolID());
    let borrowEvent = await parseBorrowEvent(tx);

    // try to redeem before maturity
    await expect(exafinMaria.repay(mariaUser.address, exaTime.nextPoolID())).to.be.revertedWith(
      errorUnmatchedPool(PoolState.VALID, PoolState.MATURED)
    );

    // Move in time to maturity
    await ethers.provider.send("evm_setNextBlockTimestamp", [exaTime.nextPoolID()]);
    await ethers.provider.send("evm_mine", []);

    // try to redeem without paying debt and fail
    await expect(
      exafinMaria.redeem(mariaUser.address, supplyEvent.amount.add(supplyEvent.commission), exaTime.nextPoolID())
    ).to.be.revertedWith(errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY));

    // repay and succeed
    await exafinMaria.repay(mariaUser.address, exaTime.nextPoolID());

    // finally redeem voucher and we expect maria to have her original amount + the comission earned - comission paid
    await exafinMaria.redeem(mariaUser.address, supplyEvent.amount.add(supplyEvent.commission), exaTime.nextPoolID());

    expect(await underlyingToken.balanceOf(mariaUser.address)).to.be.equal(
      originalAmount.add(supplyEvent.commission).sub(borrowEvent.commission)
    );
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
