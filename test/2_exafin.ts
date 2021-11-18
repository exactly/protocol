import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
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

describe("FixedLender", function () {
  let exactlyEnv: DefaultEnv;

  let underlyingToken: Contract;
  let fixedLender: Contract;
  let auditor: Contract;

  const mockedTokens = new Map([
    [
      "DAI",
      {
        decimals: 18,
        collateralRate: parseUnits("0.85"),
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
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    [owner, mariaUser] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(mockedTokens);

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    fixedLender = exactlyEnv.getFixedLender("DAI");
    auditor = exactlyEnv.auditor;

    // From Owner to User
    await underlyingToken.transfer(mariaUser.address, parseUnits("10"));
  });

  it("GetAccountSnapshot fails on an invalid pool", async () => {
    let invalidPoolID = exaTime.nextPoolID() + 3;
    await expect(
      fixedLender.getAccountSnapshot(owner.address, invalidPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("setLiquidationFee fails from third parties", async () => {
    await expect(
      fixedLender.connect(mariaUser).setLiquidationFee(parseUnits("0.04"))
    ).to.be.revertedWith("AccessControl");
  });

  it("GetTotalBorrows fails on an invalid pool", async () => {
    let invalidPoolID = exaTime.nextPoolID() + 3;
    await expect(fixedLender.getTotalBorrows(invalidPoolID)).to.be.revertedWith(
      errorGeneric(ProtocolError.INVALID_POOL_ID)
    );
  });

  it("it allows to give money to a pool", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(fixedLender.address, underlyingAmount);

    let tx = await fixedLender.supply(
      owner.address,
      underlyingAmount,
      exaTime.nextPoolID()
    );
    let event = await parseSupplyEvent(tx);

    expect(event.from).to.equal(owner.address);
    expect(event.amount).to.equal(underlyingAmount);
    expect(event.maturityDate).to.equal(exaTime.nextPoolID());

    expect(await underlyingToken.balanceOf(fixedLender.address)).to.equal(
      underlyingAmount
    );

    expect(
      (
        await fixedLender.getAccountSnapshot(
          owner.address,
          exaTime.nextPoolID()
        )
      )[0]
    ).to.be.equal(underlyingAmount.add(event.commission));
  });

  it("it doesn't allow you to give money to a pool that matured", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(fixedLender.address, underlyingAmount);

    await expect(
      fixedLender.supply(owner.address, underlyingAmount, exaTime.pastPoolID())
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.MATURED, PoolState.VALID)
    );
  });

  it("it doesn't allow you to give money to a pool that hasn't been enabled yet", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(fixedLender.address, underlyingAmount);
    const notYetEnabledPoolID = exaTime.futurePools(12).pop()! + 86400 * 7; // 1 week after the last pool

    await expect(
      fixedLender.supply(owner.address, underlyingAmount, notYetEnabledPoolID)
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID)
    );
  });

  it("it doesn't allow you to give money to a pool that is invalid", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(fixedLender.address, underlyingAmount);
    const invalidPoolID = exaTime.pastPoolID() + 666;
    await expect(
      fixedLender.supply(owner.address, underlyingAmount, invalidPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("it allows you to borrow money", async () => {
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    await fixedLenderMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );
    let tx = await fixedLenderMaria.borrow(
      parseUnits("0.8"),
      exaTime.nextPoolID()
    );
    expect(tx).to.emit(fixedLenderMaria, "Borrowed");
    let event = await parseBorrowEvent(tx);
    expect(
      await fixedLenderMaria.getTotalBorrows(exaTime.nextPoolID())
    ).to.equal(parseUnits("0.8").add(event.commission));
  });

  it("it doesn't allow you to borrow money from a pool that matured", async () => {
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    await fixedLenderMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );
    await expect(
      fixedLenderMaria.borrow(parseUnits("0.8"), exaTime.pastPoolID())
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.MATURED, PoolState.VALID)
    );
  });

  it("it doesn't allow you to borrow money from a pool that hasn't been enabled yet", async () => {
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);
    let notYetEnabledPoolID = exaTime.futurePools(12).pop()! + 86400 * 7; // 1 week after the last pool
    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    await fixedLenderMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );
    await expect(
      fixedLenderMaria.borrow(parseUnits("0.8"), notYetEnabledPoolID)
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID)
    );
  });

  it("it doesn't allow you to borrow money from a pool that is invalid", async () => {
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);
    const invalidPoolID = exaTime.pastPoolID() + 666;

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    await fixedLenderMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );
    await expect(
      fixedLenderMaria.borrow(parseUnits("0.8"), invalidPoolID)
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
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    await fixedLenderMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );
    await expect(
      fixedLenderMaria.borrow(parseUnits("0.9"), exaTime.nextPoolID())
    ).to.be.reverted;
  });

  it("it allows the mariaUser to withdraw money only after maturity", async () => {
    // give the protocol some solvency
    await underlyingToken.transfer(fixedLender.address, parseUnits("100"));
    let originalAmount = await underlyingToken.balanceOf(mariaUser.address);

    // connect through Maria
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    // supply some money and parse event
    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    let tx = await fixedLenderMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    let supplyEvent = await parseSupplyEvent(tx);

    // try to redeem before maturity
    await expect(
      fixedLenderMaria.redeem(
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
    await fixedLenderMaria.redeem(
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
    await underlyingToken.transfer(fixedLender.address, parseUnits("100"));

    // connect through Maria
    let originalAmount = await underlyingToken.balanceOf(mariaUser.address);
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    // supply some money and parse event
    await underlyingTokenUser.approve(fixedLender.address, parseUnits("5.0"));
    let txSupply = await fixedLenderMaria.supply(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    let supplyEvent = await parseSupplyEvent(txSupply);
    let tx = await fixedLenderMaria.borrow(
      parseUnits("0.8"),
      exaTime.nextPoolID()
    );
    let borrowEvent = await parseBorrowEvent(tx);

    // try to redeem before maturity
    await expect(
      fixedLenderMaria.repay(mariaUser.address, exaTime.nextPoolID())
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
      fixedLenderMaria.redeem(
        mariaUser.address,
        supplyEvent.amount.add(supplyEvent.commission),
        exaTime.nextPoolID()
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY));

    // repay and succeed
    await fixedLenderMaria.repay(mariaUser.address, exaTime.nextPoolID());

    // finally redeem voucher and we expect maria to have her original amount + the comission earned - comission paid
    await fixedLenderMaria.redeem(
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
