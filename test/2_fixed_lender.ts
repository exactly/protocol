import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import {
  DefaultEnv,
  errorGeneric,
  errorUnmatchedPool,
  applyMinFee,
  applyMaxFee,
  ExactlyEnv,
  ExaTime,
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

  let mariaUser: SignerWithAddress;
  let johnUser: SignerWithAddress;
  let owner: SignerWithAddress;
  let exaTime: ExaTime = new ExaTime();

  let snapshot: any;
  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    [owner, mariaUser, johnUser] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create({});

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    underlyingTokenETH = exactlyEnv.getUnderlying("ETH");
    fixedLender = exactlyEnv.getFixedLender("DAI");
    fixedLenderETH = exactlyEnv.getFixedLender("ETH");
    auditor = exactlyEnv.auditor;

    // From Owner to User
    await underlyingToken.transfer(mariaUser.address, parseUnits("10"));
    await underlyingTokenETH.transfer(mariaUser.address, parseUnits("10"));

    await exactlyEnv.getInterestRateModel().setPenaltyRate(parseUnits("0.02"));
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
    await expect(
      fixedLender.getTotalMpBorrows(invalidPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("it allows to give money to a pool", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(fixedLender.address, underlyingAmount);

    let tx = fixedLender.depositToMaturityPool(
      underlyingAmount,
      exaTime.nextPoolID(),
      applyMinFee(underlyingAmount)
    );
    await tx;
    await expect(tx).to.emit(fixedLender, "DepositToMaturityPool").withArgs(
      owner.address,
      underlyingAmount,
      parseUnits("0"), // commission, its zero with the mocked rate
      exaTime.nextPoolID()
    );

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
    ).to.be.equal(underlyingAmount);
  });

  it("When depositing 100 to a maturity pool with 100, expecting 110, then it reverts with TOO_MUCH_SLIPPAGE", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(fixedLender.address, underlyingAmount);

    let tx = fixedLender.depositToMaturityPool(
      underlyingAmount,
      exaTime.nextPoolID(),
      applyMaxFee(underlyingAmount)
    );
    await expect(tx).to.be.revertedWith(
      errorGeneric(ProtocolError.TOO_MUCH_SLIPPAGE)
    );
  });

  it("it doesn't allow you to give money to a pool that matured", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(fixedLender.address, underlyingAmount);

    await expect(
      fixedLender.depositToMaturityPool(
        underlyingAmount,
        exaTime.pastPoolID(),
        applyMinFee(underlyingAmount)
      )
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.MATURED, PoolState.VALID)
    );
  });

  it("it doesn't allow you to give money to a pool that hasn't been enabled yet", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(fixedLender.address, underlyingAmount);
    const notYetEnabledPoolID = exaTime.futurePools(12).pop()! + 86400 * 7; // 1 week after the last pool

    await expect(
      fixedLender.depositToMaturityPool(
        underlyingAmount,
        notYetEnabledPoolID,
        applyMinFee(underlyingAmount)
      )
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID)
    );
  });

  it("it doesn't allow you to give money to a pool that is invalid", async () => {
    const underlyingAmount = parseUnits("100");
    await underlyingToken.approve(fixedLender.address, underlyingAmount);
    const invalidPoolID = exaTime.pastPoolID() + 666;
    await expect(
      fixedLender.depositToMaturityPool(
        underlyingAmount,
        invalidPoolID,
        applyMinFee(underlyingAmount)
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("allows you to borrow money from a maturity pool", async () => {
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );
    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );
    let tx = await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.8"),
      exaTime.nextPoolID(),
      applyMaxFee(parseUnits("0.8"))
    );
    expect(tx).to.emit(fixedLenderMaria, "BorrowFromMaturityPool");
    expect(
      await fixedLenderMaria.getTotalMpBorrows(exaTime.nextPoolID())
    ).to.equal(parseUnits("0.8"));
  });

  it("WHEN trying to borrow 0.8 DAI with a max amount of debt of 0.8 DAI, but receiving more than 0.8 DAI of debt THEN it reverts with TOO_MUCH_SLIPPAGE", async () => {
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);
    await exactlyEnv.interestRateModel.setBorrowRate(parseUnits("0.02"));

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );
    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );
    let tx = fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.8"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("0.8"))
    );
    await expect(tx).to.be.revertedWith(
      errorGeneric(ProtocolError.TOO_MUCH_SLIPPAGE)
    );
  });

  it("it doesn't allow you to borrow money from a pool that matured", async () => {
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let auditorUser = auditor.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));
    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );
    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );
    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.8"),
        exaTime.pastPoolID(),
        applyMaxFee(parseUnits("0.8"))
      )
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
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );
    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );
    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.8"),
        notYetEnabledPoolID,
        applyMaxFee(parseUnits("0.8"))
      )
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
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );
    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );
    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.8"),
        invalidPoolID,
        applyMaxFee(parseUnits("0.8"))
      )
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
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );
    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );
    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.9"),
        exaTime.nextPoolID(),
        applyMaxFee(parseUnits("0.9"))
      )
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
    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );

    // try to withdraw before maturity
    await expect(
      fixedLenderMaria.withdrawFromMaturityPool(
        mariaUser.address,
        parseUnits("1"),
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

    // finally withdraw voucher and we expect maria to have her original amount + the comission earned
    await fixedLenderMaria.withdrawFromMaturityPool(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );
    expect(await underlyingToken.balanceOf(mariaUser.address)).to.be.equal(
      originalAmount
    );
  });

  it("it allows the mariaUser to repay her debt before maturity, but not withdrawing her collateral", async () => {
    // give the protocol some solvency
    await underlyingToken.transfer(fixedLender.address, parseUnits("100"));

    // connect through Maria
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("5.0"));
    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.8"),
      exaTime.nextPoolID(),
      applyMaxFee(parseUnits("0.8"))
    );

    // try to withdraw without paying debt and fail
    await expect(
      fixedLenderMaria.withdrawFromMaturityPool(
        mariaUser.address,
        0,
        exaTime.nextPoolID()
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.REDEEM_CANT_BE_ZERO));

    // repay and succeed
    await expect(
      fixedLenderMaria.repayToMaturityPool(
        mariaUser.address,
        exaTime.nextPoolID(),
        parseUnits("0.8")
      )
    ).to.not.be.reverted;

    // try to withdraw without paying debt and fail
    await expect(
      fixedLenderMaria.withdrawFromMaturityPool(
        mariaUser.address,
        parseUnits("1"),
        exaTime.nextPoolID()
      )
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.VALID, PoolState.MATURED)
    );
  });

  it("it allows mariaUser to repay her debt partially before maturity", async () => {
    // give the protocol some solvency
    await underlyingToken.transfer(fixedLender.address, parseUnits("100"));

    // connect through Maria
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("5.0"));
    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.8"),
      exaTime.nextPoolID(),
      applyMaxFee(parseUnits("0.8"))
    );

    // repay half of her debt and succeed
    await expect(
      fixedLenderMaria.repayToMaturityPool(
        mariaUser.address,
        exaTime.nextPoolID(),
        parseUnits("0.4")
      )
    ).to.not.be.reverted;

    // ... the other half is still pending
    const [, amountOwed] = await fixedLenderMaria.getAccountSnapshot(
      mariaUser.address,
      exaTime.nextPoolID()
    );

    expect(amountOwed).to.equal(parseUnits("0.4"));
  });

  it("it allows mariaUser to repay her debt partially before maturity, repay full with the rest 1 day after (1 day penalty)", async () => {
    // give the protocol some solvency
    await underlyingToken.transfer(fixedLender.address, parseUnits("100"));

    // connect through Maria
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("5.0"));
    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.8"),
      exaTime.nextPoolID(),
      applyMaxFee(parseUnits("0.8"))
    );

    // repay half of her debt and succeed
    await expect(
      fixedLenderMaria.repayToMaturityPool(
        mariaUser.address,
        exaTime.nextPoolID(),
        parseUnits("0.4")
      )
    ).to.not.be.reverted;

    // Move in time to maturity + 1 day
    await ethers.provider.send("evm_setNextBlockTimestamp", [
      exaTime.nextPoolID() + exaTime.ONE_DAY,
    ]);
    await ethers.provider.send("evm_mine", []);

    await expect(
      fixedLenderMaria.repayToMaturityPool(
        mariaUser.address,
        exaTime.nextPoolID(),
        parseUnits("0.4").mul(102).div(100)
      )
    ).to.not.be.reverted;

    const [, amountOwed] = await fixedLenderMaria.getAccountSnapshot(
      mariaUser.address,
      exaTime.nextPoolID()
    );

    expect(amountOwed).to.equal(0);
  });

  it("GetAccountSnapshot should reflect BaseRate penaltyFee for mariaUser", async () => {
    // give the protocol some solvency
    await underlyingToken.transfer(fixedLender.address, parseUnits("1000"));

    // connect through Maria
    const fixedLenderMaria = fixedLender.connect(mariaUser);
    const underlyingTokenUser = underlyingToken.connect(mariaUser);
    const penaltyRate = await exactlyEnv.interestRateModel.penaltyRate();

    // supply some money and parse event
    await underlyingTokenUser.approve(fixedLender.address, parseUnits("5"));
    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.5"),
      exaTime.nextPoolID(),
      applyMaxFee(parseUnits("0.5"))
    );

    // Move in time to maturity + 1 day
    await ethers.provider.send("evm_setNextBlockTimestamp", [
      exaTime.nextPoolID() + exaTime.ONE_DAY,
    ]);
    await ethers.provider.send("evm_mine", []);

    const [, amountOwed] = await fixedLenderMaria.getAccountSnapshot(
      mariaUser.address,
      exaTime.nextPoolID()
    );

    // if penaltyRate is 0.2 then we multiply for 1.2
    expect(amountOwed).to.equal(
      parseUnits("0.5")
        .mul(penaltyRate.add(parseUnits("1")))
        .div(parseUnits("1"))
    );
  });

  it("should charge mariaUser penaltyFee when paying her debt one day late", async () => {
    // give the protocol and John some solvency
    let johnBalancePre = parseUnits("1000");
    await underlyingToken.transfer(fixedLender.address, parseUnits("1000"));
    await underlyingToken.transfer(johnUser.address, johnBalancePre);
    await underlyingToken
      .connect(johnUser)
      .approve(fixedLender.address, johnBalancePre);

    // connect through Maria & John
    const fixedLenderMaria = fixedLender.connect(mariaUser);
    const fixedLenderJohn = fixedLender.connect(johnUser);
    const underlyingTokenMaria = underlyingToken.connect(mariaUser);
    const penaltyRate = await exactlyEnv.interestRateModel.penaltyRate();

    await fixedLenderJohn.depositToSmartPool(johnBalancePre);

    // supply some money and parse event
    await underlyingTokenMaria.approve(fixedLender.address, parseUnits("5"));
    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.5"),
      exaTime.nextPoolID(),
      applyMaxFee(parseUnits("0.5"))
    );

    // Move in time to maturity + 1 day
    await ethers.provider.send("evm_setNextBlockTimestamp", [
      exaTime.nextPoolID() + exaTime.ONE_DAY + 1,
    ]);
    await ethers.provider.send("evm_mine", []);

    // if penaltyRate is 0.02 then we multiply for 1.2
    const expectedAmountPaid = parseUnits("0.5")
      .mul(penaltyRate.add(parseUnits("1")))
      .div(parseUnits("1"));
    const amountBorrowed = parseUnits("0.5");

    await expect(
      fixedLenderMaria.repayToMaturityPool(
        mariaUser.address,
        exaTime.nextPoolID(),
        expectedAmountPaid
      )
    )
      .to.emit(fixedLenderMaria, "RepayToMaturityPool")
      .withArgs(
        mariaUser.address,
        mariaUser.address,
        expectedAmountPaid.sub(amountBorrowed),
        amountBorrowed,
        exaTime.nextPoolID()
      );

    // sanity check to make sure he paid more
    expect(amountBorrowed).not.eq(expectedAmountPaid);

    let johnBalancePost = await exactlyEnv
      .getEToken("DAI")
      .balanceOf(johnUser.address);
    expect(johnBalancePre.add(expectedAmountPaid.sub(amountBorrowed))).to.equal(
      johnBalancePost
    );
  });

  it("it allows the mariaUser to repay her debt at maturity and also withdrawing her collateral", async () => {
    // give the protocol some solvency
    await underlyingToken.transfer(fixedLender.address, parseUnits("100"));

    // connect through Maria
    let originalAmount = await underlyingToken.balanceOf(mariaUser.address);
    let fixedLenderMaria = fixedLender.connect(mariaUser);
    let underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("5.0"));
    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("1"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.8"),
      exaTime.nextPoolID(),
      applyMaxFee(parseUnits("0.8"))
    );

    // Move in time to maturity
    await ethers.provider.send("evm_setNextBlockTimestamp", [
      exaTime.nextPoolID(),
    ]);
    await ethers.provider.send("evm_mine", []);

    // try to withdraw without paying debt and fail
    await expect(
      fixedLenderMaria.withdrawFromMaturityPool(
        mariaUser.address,
        0,
        exaTime.nextPoolID()
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.REDEEM_CANT_BE_ZERO));

    // try to withdraw without paying debt and fail
    await expect(
      fixedLenderMaria.withdrawFromMaturityPool(
        mariaUser.address,
        parseUnits("1"),
        exaTime.nextPoolID()
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY));

    // repay and succeed
    await expect(
      fixedLenderMaria.repayToMaturityPool(
        mariaUser.address,
        exaTime.nextPoolID(),
        parseUnits("0.8")
      )
    ).to.not.be.reverted;

    // finally withdraw voucher and we expect maria to have her original amount + the comission earned - comission paid
    await fixedLenderMaria.withdrawFromMaturityPool(
      mariaUser.address,
      parseUnits("1"),
      exaTime.nextPoolID()
    );

    expect(await underlyingToken.balanceOf(mariaUser.address)).to.be.equal(
      originalAmount
    );
  });

  it("it doesn't allow you to borrow more money than the available", async () => {
    const fixedLenderMaria = fixedLender.connect(mariaUser);
    const auditorUser = auditor.connect(mariaUser);
    const underlyingTokenUser = underlyingToken.connect(mariaUser);

    await underlyingTokenUser.approve(fixedLender.address, parseUnits("1"));

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address],
      exaTime.nextPoolID()
    );

    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.8"),
        exaTime.nextPoolID(),
        applyMaxFee(parseUnits("0.8"))
      )
    ).to.be.revertedWith(
      errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
    );
  });

  it("it doesn't allow you to borrow when maturity and smart pool are empty", async () => {
    const fixedLenderMaria = fixedLender.connect(mariaUser);

    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.8"),
        exaTime.nextPoolID(),
        applyMaxFee(parseUnits("0.8"))
      )
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
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("0.2"))
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await fixedLender.depositToSmartPool(parseUnits("0.2"));

    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.8"),
        exaTime.nextPoolID(),
        applyMaxFee(parseUnits("0.8"))
      )
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
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("0.2"))
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.8"),
        exaTime.nextPoolID(),
        applyMaxFee(parseUnits("0.8"))
      )
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
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );

    await auditorUser.enterMarkets(
      [fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await fixedLender.depositToSmartPool(parseUnits("0.2"));

    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.8"),
        exaTime.nextPoolID(),
        applyMaxFee(parseUnits("0.8"))
      )
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
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("0.2"))
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await fixedLenderMaria.depositToSmartPool(parseUnits("0.2"));

    const borrow = fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.3"),
      exaTime.nextPoolID(),
      applyMaxFee(parseUnits("0.3"))
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
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("0.2"))
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await fixedLenderMaria.depositToSmartPool(parseUnits("0.2"));

    const borrow = fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.4"),
      exaTime.nextPoolID(),
      applyMaxFee(parseUnits("0.4"))
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
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("0.2"))
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await fixedLenderMaria.depositToSmartPool(parseUnits("0.2"));

    const borrow = fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.4"),
      exaTime.nextPoolID(),
      applyMaxFee(parseUnits("0.4"))
    );

    await expect(borrow).to.not.be.reverted;

    let poolData = await fixedLender.maturityPools(exaTime.nextPoolID());
    let debt = poolData[2];

    expect(debt).not.to.be.equal("0");

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.5"),
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("0.5"))
    );

    poolData = await fixedLender.maturityPools(exaTime.nextPoolID());
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
      exaTime.nextPoolID(),
      applyMinFee(parseUnits("1"))
    );

    await auditorUser.enterMarkets(
      [fixedLenderMariaETH.address],
      exaTime.nextPoolID()
    );

    await fixedLender.depositToSmartPool(parseUnits("1"));
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.8"),
      exaTime.nextPoolID(),
      applyMaxFee(parseUnits("0.8"))
    );

    await expect(
      fixedLender.withdrawFromSmartPool(parseUnits("1"))
    ).to.be.revertedWith(
      errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
    );
  });

  describe("Transfers with Commissions", () => {
    describe("GIVEN an underlying token with 10% comission", () => {
      beforeEach(async () => {
        await underlyingToken.setCommission(parseUnits("0.1"));
        await underlyingToken.transfer(johnUser.address, parseUnits("10000"));
      });

      describe("WHEN depositing 2000 DAI on a maturity pool", () => {
        const amount = parseUnits("2000");

        beforeEach(async () => {
          await underlyingToken
            .connect(johnUser)
            .approve(fixedLender.address, amount);
          await fixedLender
            .connect(johnUser)
            .depositToMaturityPool(
              amount,
              exaTime.nextPoolID(),
              applyMinFee(parseUnits("1800"))
            );
        });

        it("THEN the user receives 1800 on the maturity pool deposit", async () => {
          const supplied = (
            await fixedLender
              .connect(johnUser)
              .getAccountSnapshot(johnUser.address, exaTime.nextPoolID())
          )[0];
          expect(supplied).to.eq(
            amount.mul(parseUnits("0.9")).div(parseUnits("1"))
          );
        });

        describe("AND GIVEN john has a 900 DAI borrows on a maturity pool", () => {
          const amountBorrow = parseUnits("900");
          const maxAllowance = parseUnits("2000");
          beforeEach(async () => {
            await fixedLender
              .connect(johnUser)
              .borrowFromMaturityPool(
                amountBorrow,
                exaTime.nextPoolID(),
                applyMinFee(amountBorrow)
              );

            await underlyingToken
              .connect(johnUser)
              .approve(fixedLender.address, maxAllowance);
          });

          describe("AND WHEN trying to repay 1100 (too much)", () => {
            const amountToTransfer = parseUnits("1100");
            let tx: any;
            beforeEach(async () => {
              tx = fixedLender
                .connect(johnUser)
                .repayToMaturityPool(
                  johnUser.address,
                  exaTime.nextPoolID(),
                  amountToTransfer
                );
            });

            it("THEN the transaction is reverted TOO_MUCH_REPAY_TRANSFER", async () => {
              await expect(tx).to.be.revertedWith(
                errorGeneric(ProtocolError.TOO_MUCH_REPAY_TRANSFER)
              );
            });
          });

          describe("AND WHEN repaying with 10% commission", () => {
            const amountToTransfer = parseUnits("1000");
            beforeEach(async () => {
              await fixedLender
                .connect(johnUser)
                .repayToMaturityPool(
                  johnUser.address,
                  exaTime.nextPoolID(),
                  amountToTransfer
                );
            });

            it("THEN the user cancel its debt and succeeds", async () => {
              const borrowed = (
                await fixedLender
                  .connect(johnUser.address)
                  .getAccountSnapshot(johnUser.address, exaTime.nextPoolID())
              )[1];
              expect(borrowed).to.eq(0);
            });
          });
        });
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
