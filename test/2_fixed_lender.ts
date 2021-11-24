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
  parseDepositToMaturityPoolEvent,
  PoolState,
  ProtocolError,
} from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("FixedLender", function () {
  let exactlyEnv: DefaultEnv;

  let underlyingToken: Contract;
  let underlyingTokenETH: Contract;
  let fixedLender: Contract;
  let fixedLenderETH: Contract;
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
  let eDAI: Contract;

  let snapshot: any;
  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    [owner, mariaUser] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(mockedTokens);

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    underlyingTokenETH = exactlyEnv.getUnderlying("ETH");
    fixedLender = exactlyEnv.getFixedLender("DAI");
    fixedLenderETH = exactlyEnv.getFixedLender("ETH");
    auditor = exactlyEnv.auditor;

    eDAI = exactlyEnv.getEToken("DAI");
    await eDAI.setFixedLender(fixedLender.address);

    // From Owner to User
    await underlyingToken.transfer(mariaUser.address, parseUnits("10"));
    await underlyingTokenETH.transfer(mariaUser.address, parseUnits("10"));
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

    let tx = await fixedLender.depositToMaturityPool(
      underlyingAmount,
      exaTime.nextPoolID()
    );
    let event = await parseDepositToMaturityPoolEvent(tx);

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
      fixedLender.depositToMaturityPool(underlyingAmount, exaTime.pastPoolID())
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.MATURED, PoolState.VALID)
    );
  });

  it("it doesn't allow you to give money to a pool that hasn't been enabled yet", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(fixedLender.address, underlyingAmount);
    const notYetEnabledPoolID = exaTime.futurePools(12).pop()! + 86400 * 7; // 1 week after the last pool

    await expect(
      fixedLender.depositToMaturityPool(underlyingAmount, notYetEnabledPoolID)
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID)
    );
  });

  it("it doesn't allow you to give money to a pool that is invalid", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(fixedLender.address, underlyingAmount);
    const invalidPoolID = exaTime.pastPoolID() + 666;
    await expect(
      fixedLender.depositToMaturityPool(underlyingAmount, invalidPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("it allows you to borrow money", async () => {
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    await fixedLenderMaria.depositToMaturityPool(
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
    await fixedLenderMaria.depositToMaturityPool(
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
    await fixedLenderMaria.depositToMaturityPool(
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
    await fixedLenderMaria.depositToMaturityPool(
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
    await fixedLenderMaria.depositToMaturityPool(
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

    // deposit some money and parse event
    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    let tx = await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    let depositEvent = await parseDepositToMaturityPoolEvent(tx);

    // try to redeem before maturity
    await expect(
      fixedLenderMaria.redeem(
        mariaUser.address,
        depositEvent.amount.add(depositEvent.commission),
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
      depositEvent.amount.add(depositEvent.commission),
      exaTime.nextPoolID()
    );
    expect(await underlyingToken.balanceOf(mariaUser.address)).to.be.equal(
      originalAmount.add(depositEvent.commission)
    );
  });

  it("it allows the mariaUser to repay her debt before maturity, but not redeeming her collateral", async () => {
    // give the protocol some solvency
    await underlyingToken.transfer(fixedLender.address, parseUnits("100"));

    // connect through Maria
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    // supply some money and parse event
    await underlyingTokenUser.approve(fixedLender.address, parseUnits("5.0"));
    let txSupply = await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    let depositEvent = await parseDepositToMaturityPoolEvent(txSupply);
    await fixedLenderMaria.borrow(parseUnits("0.8"), exaTime.nextPoolID());

    // try to redeem without paying debt and fail
    await expect(
      fixedLenderMaria.redeem(mariaUser.address, 0, exaTime.nextPoolID())
    ).to.be.revertedWith(errorGeneric(ProtocolError.REDEEM_CANT_BE_ZERO));

    // repay and succeed
    await expect(
      fixedLenderMaria.repay(mariaUser.address, exaTime.nextPoolID())
    ).to.not.be.reverted;

    // try to redeem without paying debt and fail
    await expect(
      fixedLenderMaria.redeem(
        mariaUser.address,
        depositEvent.amount.add(depositEvent.commission),
        exaTime.nextPoolID()
      )
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.VALID, PoolState.MATURED)
    );
  });

  it("it allows the mariaUser to repay her debt at maturity and also redeeming her collateral", async () => {
    // give the protocol some solvency
    await underlyingToken.transfer(fixedLender.address, parseUnits("100"));

    // connect through Maria
    let originalAmount = await underlyingToken.balanceOf(mariaUser.address);
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    // supply some money and parse event
    await underlyingTokenUser.approve(fixedLender.address, parseUnits("5.0"));
    let txSupply = await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    let depositEvent = await parseDepositToMaturityPoolEvent(txSupply);
    let tx = await fixedLenderMaria.borrow(
      parseUnits("0.8"),
      exaTime.nextPoolID()
    );
    let borrowEvent = await parseBorrowEvent(tx);

    // Move in time to maturity
    await ethers.provider.send("evm_setNextBlockTimestamp", [
      exaTime.nextPoolID(),
    ]);
    await ethers.provider.send("evm_mine", []);

    // try to redeem without paying debt and fail
    await expect(
      fixedLenderMaria.redeem(mariaUser.address, 0, exaTime.nextPoolID())
    ).to.be.revertedWith(errorGeneric(ProtocolError.REDEEM_CANT_BE_ZERO));

    // try to redeem without paying debt and fail
    await expect(
      fixedLenderMaria.redeem(
        mariaUser.address,
        depositEvent.amount.add(depositEvent.commission),
        exaTime.nextPoolID()
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY));

    // repay and succeed
    await expect(
      fixedLenderMaria.repay(mariaUser.address, exaTime.nextPoolID())
    ).to.not.be.reverted;

    // finally redeem voucher and we expect maria to have her original amount + the comission earned - comission paid
    await fixedLenderMaria.redeem(
      mariaUser.address,
      depositEvent.amount.add(depositEvent.commission),
      exaTime.nextPoolID()
    );

    expect(await underlyingToken.balanceOf(mariaUser.address)).to.be.equal(
      originalAmount.add(depositEvent.commission).sub(borrowEvent.commission)
    );
  });

  it("it doesn't allow you to borrow more money that the available", async () => {
    const fixedLenderMaria = fixedLender.connect(mariaUser);
    const auditorUser = auditor.connect(mariaUser);
    const underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );

    await expect(
      fixedLenderMaria.borrow(parseUnits("0.8"), exaTime.nextPoolID())
    ).to.be.revertedWith(
      errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
    );
  });

  it("it doesn't allow you to borrow when maturity and smart pool are empty", async () => {
    const fixedLenderMaria = fixedLender.connect(mariaUser);

    await expect(
      fixedLenderMaria.borrow(parseUnits("0.8"), exaTime.nextPoolID())
    ).to.be.revertedWith(
      errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
    );
  });

  it("it doesn't allow you to borrow when the sum of the available amount in the smart and the maturity is lower than what is asked", async () => {
    const fixedLenderMaria = fixedLender.connect(mariaUser);
    const fixedLenderMariaETH = fixedLenderETH.connect(mariaUser);

    const underlyingTokenUser = underlyingToken.connect(mariaUser);
    const underlyingTokenUserETH = underlyingTokenETH.connect(mariaUser);

    const auditorUser = auditor.connect(mariaUser);

    await underlyingToken.approve(fixedLender.address, parseUnits("10"));
    await underlyingTokenUser.approve(fixedLender.address, parseUnits("10"));
    await underlyingTokenUserETH.approve(
      fixedLenderETH.address,
      parseUnits("1")
    );

    await fixedLenderMariaETH.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID()
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      exaTime.nextPoolID()
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await fixedLender.depositToSmartPool(parseUnits("0.2"));

    await expect(
      fixedLenderMaria.borrow(parseUnits("0.8"), exaTime.nextPoolID())
    ).to.be.revertedWith(
      errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
    );
  });

  it("it doesn't allow you to borrow when no money in the smart pool and you ask for more than available in maturity", async () => {
    const fixedLenderMaria = fixedLender.connect(mariaUser);
    const fixedLenderMariaETH = fixedLenderETH.connect(mariaUser);

    const underlyingTokenUser = underlyingToken.connect(mariaUser);
    const underlyingTokenUserETH = underlyingTokenETH.connect(mariaUser);

    const auditorUser = auditor.connect(mariaUser);

    await underlyingToken.approve(fixedLender.address, parseUnits("10"));
    await underlyingTokenUser.approve(fixedLender.address, parseUnits("10"));
    await underlyingTokenUserETH.approve(
      fixedLenderETH.address,
      parseUnits("1")
    );

    await fixedLenderMariaETH.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID()
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      exaTime.nextPoolID()
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await expect(
      fixedLenderMaria.borrow(parseUnits("0.8"), exaTime.nextPoolID())
    ).to.be.revertedWith(
      errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
    );
  });

  it("it doesn't allow you to borrow when no money in the maturity pool and you ask for more than available in smart pool", async () => {
    const fixedLenderMaria = fixedLender.connect(mariaUser);
    const fixedLenderMariaETH = fixedLenderETH.connect(mariaUser);

    const underlyingTokenUser = underlyingToken.connect(mariaUser);
    const underlyingTokenUserETH = underlyingTokenETH.connect(mariaUser);

    const auditorUser = auditor.connect(mariaUser);

    await underlyingToken.approve(fixedLender.address, parseUnits("10"));
    await underlyingTokenUser.approve(fixedLender.address, parseUnits("10"));
    await underlyingTokenUserETH.approve(
      fixedLenderETH.address,
      parseUnits("1")
    );

    await fixedLenderMariaETH.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID()
    );

    await auditorUser.enterMarkets(
      [fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await fixedLender.depositToSmartPool(parseUnits("0.2"));

    await expect(
      fixedLenderMaria.borrow(parseUnits("0.8"), exaTime.nextPoolID())
    ).to.be.revertedWith(
      errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
    );
  });

  it("it allows you to borrow when the sum of the available amount in the smart and the maturity is higher than what is asked", async () => {
    const fixedLenderMaria = fixedLender.connect(mariaUser);
    const fixedLenderMariaETH = fixedLenderETH.connect(mariaUser);

    const underlyingTokenUser = underlyingToken.connect(mariaUser);
    const underlyingTokenUserETH = underlyingTokenETH.connect(mariaUser);

    const auditorUser = auditor.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    await underlyingTokenUserETH.approve(
      fixedLenderETH.address,
      parseUnits("1")
    );

    await fixedLenderMariaETH.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID()
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      exaTime.nextPoolID()
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await fixedLenderMaria.depositToSmartPool(parseUnits("0.2"));

    const borrow = fixedLenderMaria.borrow(
      parseUnits("0.3"),
      exaTime.nextPoolID()
    );

    await expect(borrow).to.not.be.reverted;
  });

  it("it allows you to borrow when the sum of the available amount in the smart and the maturity is exact what is asked", async () => {
    const fixedLenderMaria = fixedLender.connect(mariaUser);
    const fixedLenderMariaETH = fixedLenderETH.connect(mariaUser);

    const underlyingTokenUser = underlyingToken.connect(mariaUser);
    const underlyingTokenUserETH = underlyingTokenETH.connect(mariaUser);

    const auditorUser = auditor.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    await underlyingTokenUserETH.approve(
      fixedLenderETH.address,
      parseUnits("1")
    );

    await fixedLenderMariaETH.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID()
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      exaTime.nextPoolID()
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await fixedLenderMaria.depositToSmartPool(parseUnits("0.2"));

    const borrow = fixedLenderMaria.borrow(
      parseUnits("0.4"),
      exaTime.nextPoolID()
    );

    await expect(borrow).to.not.be.reverted;
  });

  it("supply enough money to a maturity pool that owes money so it is repaid", async () => {
    const fixedLenderMaria = fixedLender.connect(mariaUser);
    const fixedLenderMariaETH = fixedLenderETH.connect(mariaUser);

    const underlyingTokenUser = underlyingToken.connect(mariaUser);
    const underlyingTokenUserETH = underlyingTokenETH.connect(mariaUser);

    const auditorUser = auditor.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    await underlyingTokenUserETH.approve(
      fixedLenderETH.address,
      parseUnits("1")
    );

    await fixedLenderMariaETH.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID()
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      exaTime.nextPoolID()
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await fixedLenderMaria.depositToSmartPool(parseUnits("0.2"));

    const borrow = fixedLenderMaria.borrow(
      parseUnits("0.4"),
      exaTime.nextPoolID()
    );

    await expect(borrow).to.not.be.reverted;

    let poolData = await fixedLender.pools(exaTime.nextPoolID());
    let debt = poolData[2];

    expect(debt).not.to.be.equal("0");

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.5"),
      exaTime.nextPoolID()
    );

    poolData = await fixedLender.pools(exaTime.nextPoolID());
    debt = poolData[2];
    expect(debt).to.be.equal("0");
  });

  it("it doesn't allow you to borrow from smart pool if not enough liquidity", async () => {
    const fixedLenderMaria = fixedLender.connect(mariaUser);
    const fixedLenderMariaETH = fixedLenderETH.connect(mariaUser);

    const underlyingTokenUser = underlyingToken.connect(mariaUser);
    const underlyingTokenUserETH = underlyingTokenETH.connect(mariaUser);

    const auditorUser = auditor.connect(mariaUser);

    await underlyingToken.approve(fixedLender.address, parseUnits("10"));
    await underlyingTokenUser.approve(fixedLender.address, parseUnits("10"));
    await underlyingTokenUserETH.approve(
      fixedLenderETH.address,
      parseUnits("1")
    );

    await fixedLenderMariaETH.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID()
    );

    await auditorUser.enterMarkets(
      [fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await fixedLender.depositToSmartPool(parseUnits("1"));
    await fixedLenderMaria.borrow(parseUnits("0.8"), exaTime.nextPoolID());

    await expect(
      fixedLender.withdrawFromSmartPool(parseUnits("1"))
    ).to.be.revertedWith(
      errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
    );
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
