import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract, BigNumber } from "ethers";
import {
  DefaultEnv,
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

describe("Exafin", function () {
  let exactlyEnv: DefaultEnv;

  let underlyingToken: Contract;
  let exafin: Contract;
  let auditor: Contract;

  const mockedTokens = new Map([
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
        usdPrice: parseUnits("3100"),
      },
    ],
  ]);

  let mariaUser: SignerWithAddress;
  let owner: SignerWithAddress;
  let exaTime: ExaTime = new ExaTime();

  let snapshot: any;

  beforeEach(async () => {
    [owner, mariaUser] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(mockedTokens);

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    exafin = exactlyEnv.getExafin("DAI");
    auditor = exactlyEnv.auditor;

    // From Owner to User
    await underlyingToken.transfer(mariaUser.address, parseUnits("10"));

    // This can be optimized (so we only do it once per file, not per test)
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  it("GetAccountSnapshot fails on an invalid pool", async () => {
    let invalidPoolID = exaTime.nextPoolID() + 3;
    await expect(
      exafin.getAccountSnapshot(owner.address, invalidPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("GetTotalBorrows fails on an invalid pool", async () => {
    let invalidPoolID = exaTime.nextPoolID() + 3;
    await expect(exafin.getTotalBorrows(invalidPoolID)).to.be.revertedWith(
      errorGeneric(ProtocolError.INVALID_POOL_ID)
    );
  });

  it("GetRateToSupply fails on an invalid pool", async () => {
    let invalidPoolID = exaTime.nextPoolID() + 3;
    await expect(
      exafin.getRateToSupply(parseUnits("10"), invalidPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("GetRateToBorrow fails on an invalid pool", async () => {
    let invalidPoolID = exaTime.nextPoolID() + 3;
    await expect(
      exafin.getRateToBorrow(parseUnits("10"), invalidPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("it allows to give money to a pool", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(exafin.address, underlyingAmount);

    let tx = await exafin.supply(
      owner.address,
      underlyingAmount,
      exaTime.nextPoolID()
    );
    let event = await parseSupplyEvent(tx);

    expect(event.from).to.equal(owner.address);
    expect(event.amount).to.equal(underlyingAmount);
    expect(event.maturityDate).to.equal(exaTime.nextPoolID());

    expect(await underlyingToken.balanceOf(exafin.address)).to.equal(
      underlyingAmount
    );

    expect(
      (await exafin.getAccountSnapshot(owner.address, exaTime.nextPoolID()))[0]
    ).to.be.equal(underlyingAmount);
  });

  it("it doesn't allow you to give money to a pool that matured", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(exafin.address, underlyingAmount);

    await expect(
      exafin.supply(owner.address, underlyingAmount, exaTime.pastPoolID())
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.MATURED, PoolState.VALID)
    );
  });

  it("it doesn't allow you to give money to a pool that hasn't been enabled yet", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(exafin.address, underlyingAmount);
    const notYetEnabledPoolID = exaTime.futurePools(12).pop()! + 86400 * 7; // 1 week after the last pool

    await expect(
      exafin.supply(owner.address, underlyingAmount, notYetEnabledPoolID)
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID)
    );
  });

  it("it doesn't allow you to give money to a pool that is invalid", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(exafin.address, underlyingAmount);
    const invalidPoolID = exaTime.pastPoolID() + 666;
    await expect(
      exafin.supply(owner.address, underlyingAmount, invalidPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("it doesn't allow you to enter a market with an invalid pool id", async () => {
    const invalidPoolID = exaTime.pastPoolID() + 666;
    await expect(
      auditor.enterMarkets([exafin.address], invalidPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("it doesn't allow you to enter an invalid market", async () => {
    await expect(
      auditor.enterMarkets(
        [exactlyEnv.notAnExafinAddress],
        exaTime.nextPoolID()
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
  });

  it("it allows you to borrow money", async () => {
    let exafinMaria = exafin.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(exafin.address, parseUnits("1"));
    await exafinMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    await auditorUser.enterMarkets([exafinMaria.address], exaTime.nextPoolID());
    let tx = await exafinMaria.borrow(parseUnits("0.8"), exaTime.nextPoolID());
    expect(tx).to.emit(exafinMaria, "Borrowed");
    let event = await parseBorrowEvent(tx);
    expect(await exafinMaria.getTotalBorrows(exaTime.nextPoolID())).to.equal(
      parseUnits("0.8").add(event.commission)
    );
  });

  it("it doesn't allow you to borrow money from a pool that matured", async () => {
    let exafinMaria = exafin.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(exafin.address, parseUnits("1"));
    await exafinMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    await auditorUser.enterMarkets([exafinMaria.address], exaTime.nextPoolID());
    await expect(
      exafinMaria.borrow(parseUnits("0.8"), exaTime.pastPoolID())
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.MATURED, PoolState.VALID)
    );
  });

  it("it doesn't allow you to borrow money from a pool that hasn't been enabled yet", async () => {
    let exafinMaria = exafin.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);
    let notYetEnabledPoolID = exaTime.futurePools(12).pop()! + 86400 * 7; // 1 week after the last pool
    await underlyingTokenUser.approve(exafin.address, parseUnits("1"));
    await exafinMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    await auditorUser.enterMarkets([exafinMaria.address], exaTime.nextPoolID());
    await expect(
      exafinMaria.borrow(parseUnits("0.8"), notYetEnabledPoolID)
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID)
    );
  });

  it("it doesn't allow you to borrow money from a pool that is invalid", async () => {
    let exafinMaria = exafin.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);
    const invalidPoolID = exaTime.pastPoolID() + 666;

    await underlyingTokenUser.approve(exafin.address, parseUnits("1"));
    await exafinMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    await auditorUser.enterMarkets([exafinMaria.address], exaTime.nextPoolID());
    await expect(
      exafinMaria.borrow(parseUnits("0.8"), invalidPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("Check if requirePoolState returns INVALID", async () => {
    let auditorUser = auditor.connect(mariaUser);
    const invalidPoolID = exaTime.pastPoolID() + 666;

    await expect(
      auditorUser.requirePoolState(invalidPoolID, PoolState.VALID)
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.INVALID, PoolState.VALID)
    );
  });

  it("it doesnt allow mariaUser to borrow money because not collateralized enough", async () => {
    let exafinMaria = exafin.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(exafin.address, parseUnits("1"));
    await exafinMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    await auditorUser.enterMarkets([exafinMaria.address], exaTime.nextPoolID());
    await expect(exafinMaria.borrow(parseUnits("0.9"), exaTime.nextPoolID())).to
      .be.reverted;
  });

  it("Calculates the right rate to supply", async () => {
    let exafinMaria = exafin.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);
    let unitsToSupply = parseUnits("1");

    let rateSupplyToApply = await exafinMaria.getRateToSupply(
      unitsToSupply,
      exaTime.nextPoolID()
    );
    // We supply the money
    await underlyingTokenUser.approve(exafin.address, unitsToSupply);
    let tx = await exafinMaria.supply(
      mariaUser.address,
      unitsToSupply,
      exaTime.nextPoolID()
    );
    let supplyEvent = await parseSupplyEvent(tx);

    // We expect that the actual rate was taken when we submitted the supply transaction
    expect(supplyEvent.commission).to.be.closeTo(
      unitsToSupply.mul(rateSupplyToApply).div(parseUnits("1")),
      20
    );
  });

  it("Calculates the right rate to borrow", async () => {
    let exafinMaria = exafin.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);
    let unitsToSupply = parseUnits("1");
    let unitsToBorrow = parseUnits("0.8");

    await underlyingTokenUser.approve(exafin.address, unitsToSupply);
    await exafinMaria.supply(
      mariaUser.address,
      unitsToSupply,
      exaTime.nextPoolID()
    );

    let rateBorrowToApply = await exafinMaria.getRateToBorrow(
      unitsToBorrow,
      exaTime.nextPoolID()
    );

    let tx = await exafinMaria.borrow(unitsToBorrow, exaTime.nextPoolID());
    expect(tx).to.emit(exafinMaria, "Borrowed");
    let borrowEvent = await parseBorrowEvent(tx);

    // It should be the base rate since there are no other deposits
    let nextExpirationDate = exaTime.nextPoolID();
    let daysToExpiration = exaTime.daysDiffWith(nextExpirationDate);

    // We just receive the multiplying factor for the amount "rateBorrowToApply"
    // so by multiplying we get the APY
    let yearlyRateProjected = BigNumber.from(rateBorrowToApply)
      .mul(365)
      .div(daysToExpiration);

    // This Rate is purely calculated on JS/TS side
    let yearlyRateCalculated = exactlyEnv.marginRate.add(
      exactlyEnv.slopeRate.mul(unitsToBorrow).div(unitsToSupply)
    );

    // Expected "85999999999999996" (changes from day to day) to be within 1000 of 86000000000000000
    expect(yearlyRateProjected).to.be.closeTo(yearlyRateCalculated, 1000);

    // We expect that the actual rate was taken when we submitted the borrowing transaction
    expect(borrowEvent.commission).to.be.closeTo(
      unitsToBorrow.mul(rateBorrowToApply).div(parseUnits("1")),
      1000
    );
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
    let tx = await exafinMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    let supplyEvent = await parseSupplyEvent(tx);

    // try to redeem before maturity
    await expect(
      exafinMaria.redeem(
        mariaUser.address,
        supplyEvent.amount.add(supplyEvent.commission),
        exaTime.nextPoolID()
      )
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.VALID, PoolState.MATURED)
    );

    // Move in time to maturity
    await ethers.provider.send("evm_setNextBlockTimestamp", [
      exaTime.nextPoolID(),
    ]);
    await ethers.provider.send("evm_mine", []);

    // finally redeem voucher and we expect maria to have her original amount + the comission earned
    await exafinMaria.redeem(
      mariaUser.address,
      supplyEvent.amount.add(supplyEvent.commission),
      exaTime.nextPoolID()
    );
    expect(await underlyingToken.balanceOf(mariaUser.address)).to.be.equal(
      originalAmount.add(supplyEvent.commission)
    );
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
    let txSupply = await exafinMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    let supplyEvent = await parseSupplyEvent(txSupply);
    let tx = await exafinMaria.borrow(parseUnits("0.8"), exaTime.nextPoolID());
    let borrowEvent = await parseBorrowEvent(tx);

    // try to redeem before maturity
    await expect(
      exafinMaria.repay(mariaUser.address, exaTime.nextPoolID())
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.VALID, PoolState.MATURED)
    );

    // Move in time to maturity
    await ethers.provider.send("evm_setNextBlockTimestamp", [
      exaTime.nextPoolID(),
    ]);
    await ethers.provider.send("evm_mine", []);

    // try to redeem without paying debt and fail
    await expect(
      exafinMaria.redeem(
        mariaUser.address,
        supplyEvent.amount.add(supplyEvent.commission),
        exaTime.nextPoolID()
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY));

    // repay and succeed
    await exafinMaria.repay(mariaUser.address, exaTime.nextPoolID());

    // finally redeem voucher and we expect maria to have her original amount + the comission earned - comission paid
    await exafinMaria.redeem(
      mariaUser.address,
      supplyEvent.amount.add(supplyEvent.commission),
      exaTime.nextPoolID()
    );

    expect(await underlyingToken.balanceOf(mariaUser.address)).to.be.equal(
      originalAmount.add(supplyEvent.commission).sub(borrowEvent.commission)
    );
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
