import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import {
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
import { DefaultEnv } from "./defaultEnv";

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
  const exaTime: ExaTime = new ExaTime();
  const nextPoolId: number = exaTime.nextPoolID();
  const laterPoolId: number = nextPoolId + exaTime.INTERVAL;

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
    await underlyingToken.transfer(mariaUser.address, parseUnits("100000"));
    await underlyingTokenETH.transfer(mariaUser.address, parseUnits("100000"));
    await underlyingToken.transfer(johnUser.address, parseUnits("100000"));

    await exactlyEnv.getInterestRateModel().setPenaltyRate(parseUnits("0.02"));
    exactlyEnv.switchWallet(mariaUser);
  });

  describe("WHEN depositing 100 DAI to a maturity pool (with a collateralization rate of 80%)", () => {
    let tx: any;
    beforeEach(async () => {
      tx = exactlyEnv.depositMP("DAI", exaTime.nextPoolID(), "100");
      await tx;
    });
    it("THEN a DepositToMaturityPool event is emitted", async () => {
      await expect(tx).to.emit(fixedLender, "DepositToMaturityPool").withArgs(
        mariaUser.address,
        parseUnits("100"),
        parseUnits("0"), // commission, its zero with the mocked rate
        nextPoolId
      );
    });
    it("AND the FixedLender contract has a balance of 100 DAI", async () => {
      expect(await underlyingToken.balanceOf(fixedLender.address)).to.equal(
        parseUnits("100")
      );
    });
    it("AND the FixedLender registers a supply of 100 DAI for the user (exposed via getAccountSnapshot)", async () => {
      expect(
        (await fixedLender.getAccountSnapshot(mariaUser.address, nextPoolId))[0]
      ).to.be.equal(parseUnits("100"));
    });
    it("AND WHEN trying to withdraw before the pool matures, THEN it reverts", async () => {
      // try to withdraw before maturity
      await expect(
        exactlyEnv.withdrawMP("DAI", exaTime.nextPoolID(), "100")
      ).to.be.revertedWith(
        errorUnmatchedPool(PoolState.VALID, PoolState.MATURED)
      );
    });
    it("WHEN trying to borrow 90 DAI THEN it reverts with INSUFFICIENT_LIQUIDITY", async () => {
      await expect(
        exactlyEnv.borrowMP("DAI", exaTime.nextPoolID(), "90")
      ).to.be.revertedWith(errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY));
    });

    describe("WHEN borrowing 80 DAI from the same maturity", () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.borrowMP("DAI", exaTime.nextPoolID(), "80");
        await tx;
      });
      it("THEN a BorrowFromMaturityPool event is emmitted", async () => {
        await expect(tx)
          .to.emit(exactlyEnv.getFixedLender("DAI"), "BorrowFromMaturityPool")
          .withArgs(
            mariaUser.address,
            parseUnits("80"),
            parseUnits("0"),
            nextPoolId
          );
      });
      it("AND a 80DAI borrow is registered", async () => {
        expect(
          await exactlyEnv
            .getFixedLender("DAI")
            .getTotalMpBorrows(exaTime.nextPoolID())
        ).to.equal(parseUnits("80"));
      });
      describe("AND WHEN repaying the debt", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.repayMP("DAI", exaTime.nextPoolID(), "80");
          await tx;
        });
        it("THEN a RepayToMaturityPool event is emitted", async () => {
          await expect(tx)
            .to.emit(exactlyEnv.getFixedLender("DAI"), "RepayToMaturityPool")
            .withArgs(
              mariaUser.address,
              mariaUser.address,
              parseUnits("0"),
              parseUnits("80"),
              nextPoolId
            );
        });
        it("AND WHEN withdrawing the collateral, THEN it reverts because the pool isnt mature yet", async () => {
          await expect(
            exactlyEnv.withdrawMP("DAI", exaTime.nextPoolID(), "100")
          ).to.be.revertedWith(
            errorUnmatchedPool(PoolState.VALID, PoolState.MATURED)
          );
        });
      });
    });

    describe("AND WHEN moving in time to maturity AND withdrawing from the maturity pool", () => {
      let tx: any;
      beforeEach(async () => {
        await exactlyEnv.moveInTime(exaTime.nextPoolID());
        tx = await exactlyEnv.withdrawMP("DAI", exaTime.nextPoolID(), "100");
      });
      it("THEN 100 DAI are returned to Maria", async () => {
        expect(await underlyingToken.balanceOf(mariaUser.address)).to.eq(
          parseUnits("100000")
        );
        expect(await underlyingToken.balanceOf(fixedLender.address)).to.eq(
          parseUnits("0")
        );
      });
      it("AND a WithdrawFromMaturityPool event is emitted", async () => {
        await expect(tx)
          .to.emit(fixedLender, "WithdrawFromMaturityPool")
          .withArgs(mariaUser.address, parseUnits("100"), exaTime.nextPoolID());
      });
    });
  });

  describe("simple validations:", () => {
    describe("invalid pool ids", () => {
      it("WHEN calling auditor.requirePoolState directly with an invalid pool id, THEN it reverts", async () => {
        let auditorUser = auditor.connect(mariaUser);
        const invalidPoolID = exaTime.pastPoolID() + 666;

        await expect(
          auditorUser.requirePoolState(invalidPoolID, PoolState.VALID)
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.INVALID, PoolState.VALID)
        );
      });
      it("WHEN calling getAccountSnapshot on an invalid pool, THEN it reverts with INVALID_POOL_ID", async () => {
        let invalidPoolID = nextPoolId + 3;
        await expect(
          fixedLender.getAccountSnapshot(owner.address, invalidPoolID)
        ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
      });

      it("WHEN calling getTotalMpBorrows on an invalid pool, THEN it reverts with INVALID_POOL_ID", async () => {
        let invalidPoolID = nextPoolId + 3;
        await expect(
          fixedLender.getTotalMpBorrows(invalidPoolID)
        ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
      });

      it("WHEN trying to deposit to an invalid pool THEN it reverts with INVALID_POOL_ID", async () => {
        await expect(
          exactlyEnv.depositMP("DAI", exaTime.invalidPoolID(), "100")
        ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
      });
      it("WHEN trying to borrow to an invalid pool THEN it reverts ", async () => {
        await expect(
          exactlyEnv.borrowMP("DAI", exaTime.invalidPoolID(), "3", "3")
        ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
      });
    });
    describe("actions enabled/disabled at different pool stages", () => {
      it("WHEN trying to deposit to an already-matured pool, THEN it reverts", async () => {
        await expect(
          exactlyEnv.depositMP("DAI", exaTime.pastPoolID(), "100")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.MATURED, PoolState.VALID)
        );
      });

      it("WHEN depositing into a maturity very far into the future THEN it reverts", async () => {
        await expect(
          exactlyEnv.depositMP("DAI", exaTime.distantFuturePoolID(), "100")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID)
        );
      });

      it("WHEN trying to borrow from an already-matured pool THEN it reverts ", async () => {
        await expect(
          exactlyEnv.borrowMP("DAI", exaTime.pastPoolID(), "2", "2")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.MATURED, PoolState.VALID)
        );
      });

      it("WHEN trying to borrow from a not-yet-enabled pool THEN it reverts ", async () => {
        await expect(
          exactlyEnv.borrowMP("DAI", exaTime.distantFuturePoolID(), "2", "2")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID)
        );
      });
    });
    it("WHEN calling setLiquidationFee from a regular (non-admin) user, THEN it reverts with an AccessControl error", async () => {
      await expect(
        fixedLender.connect(mariaUser).setLiquidationFee(parseUnits("0.04"))
      ).to.be.revertedWith("AccessControl");
    });
  });

  describe("GIVEN an interest rate of 2%", () => {
    beforeEach(async () => {
      await exactlyEnv.setBorrowRate("0.02");

      await exactlyEnv.depositMP("DAI", exaTime.nextPoolID(), "1");
      await exactlyEnv.enterMarkets(["DAI"], exaTime.nextPoolID());
    });
    it("WHEN trying to borrow 0.8 DAI with a max amount of debt of 0.8 DAI, THEN it reverts with TOO_MUCH_SLIPPAGE", async () => {
      await expect(
        exactlyEnv.borrowMP("DAI", exaTime.nextPoolID(), "0.8", "0.8")
      ).to.be.revertedWith(errorGeneric(ProtocolError.TOO_MUCH_SLIPPAGE));
    });

    it("WHEN trying to deposit 100 DAI with a minimum required amount to be received of 103, THEN 102 are received instead AND the transaction reverts with TOO_MUCH_SLIPPAGE", async () => {
      await underlyingToken.approve(fixedLender.address, parseUnits("100"));

      let tx = fixedLender.depositToMaturityPool(
        parseUnits("100"),
        nextPoolId,
        parseUnits("103")
      );
      await expect(tx).to.be.revertedWith(
        errorGeneric(ProtocolError.TOO_MUCH_SLIPPAGE)
      );
    });
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
      nextPoolId,
      applyMinFee(parseUnits("1"))
    );
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.8"),
      nextPoolId,
      applyMaxFee(parseUnits("0.8"))
    );

    // repay half of her debt and succeed
    await expect(
      fixedLenderMaria.repayToMaturityPool(
        mariaUser.address,
        nextPoolId,
        parseUnits("0.4")
      )
    ).to.not.be.reverted;

    // ... the other half is still pending
    const [, amountOwed] = await fixedLenderMaria.getAccountSnapshot(
      mariaUser.address,
      nextPoolId
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
      nextPoolId,
      applyMinFee(parseUnits("1"))
    );
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.8"),
      nextPoolId,
      applyMaxFee(parseUnits("0.8"))
    );

    // repay half of her debt and succeed
    await expect(
      fixedLenderMaria.repayToMaturityPool(
        mariaUser.address,
        nextPoolId,
        parseUnits("0.4")
      )
    ).to.not.be.reverted;

    // Move in time to maturity + 1 day
    await ethers.provider.send("evm_setNextBlockTimestamp", [
      nextPoolId + exaTime.ONE_DAY,
    ]);
    await ethers.provider.send("evm_mine", []);

    await expect(
      fixedLenderMaria.repayToMaturityPool(
        mariaUser.address,
        nextPoolId,
        parseUnits("0.4").mul(102).div(100)
      )
    ).to.not.be.reverted;

    const [, amountOwed] = await fixedLenderMaria.getAccountSnapshot(
      mariaUser.address,
      nextPoolId
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
      nextPoolId,
      applyMinFee(parseUnits("1"))
    );
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.5"),
      nextPoolId,
      applyMaxFee(parseUnits("0.5"))
    );

    // Move in time to maturity + 1 day
    await ethers.provider.send("evm_setNextBlockTimestamp", [
      nextPoolId + exaTime.ONE_DAY,
    ]);
    await ethers.provider.send("evm_mine", []);

    const [, amountOwed] = await fixedLenderMaria.getAccountSnapshot(
      mariaUser.address,
      nextPoolId
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
      nextPoolId,
      applyMinFee(parseUnits("1"))
    );
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.5"),
      nextPoolId,
      applyMaxFee(parseUnits("0.5"))
    );

    // Move in time to maturity + 1 day
    await ethers.provider.send("evm_setNextBlockTimestamp", [
      nextPoolId + exaTime.ONE_DAY + 1,
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
        nextPoolId,
        expectedAmountPaid
      )
    )
      .to.emit(fixedLenderMaria, "RepayToMaturityPool")
      .withArgs(
        mariaUser.address,
        mariaUser.address,
        expectedAmountPaid.sub(amountBorrowed),
        amountBorrowed,
        nextPoolId
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
      nextPoolId,
      applyMinFee(parseUnits("1"))
    );
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.8"),
      nextPoolId,
      applyMaxFee(parseUnits("0.8"))
    );

    // Move in time to maturity
    await ethers.provider.send("evm_setNextBlockTimestamp", [nextPoolId]);
    await ethers.provider.send("evm_mine", []);

    // try to withdraw without paying debt and fail
    await expect(
      fixedLenderMaria.withdrawFromMaturityPool(
        mariaUser.address,
        0,
        nextPoolId
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.REDEEM_CANT_BE_ZERO));

    // try to withdraw without paying debt and fail
    await expect(
      fixedLenderMaria.withdrawFromMaturityPool(
        mariaUser.address,
        parseUnits("1"),
        nextPoolId
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY));

    // repay and succeed
    await expect(
      fixedLenderMaria.repayToMaturityPool(
        mariaUser.address,
        nextPoolId,
        parseUnits("0.8")
      )
    ).to.not.be.reverted;

    // finally withdraw voucher and we expect maria to have her original amount + the comission earned - comission paid
    await fixedLenderMaria.withdrawFromMaturityPool(
      mariaUser.address,
      parseUnits("1"),
      nextPoolId
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

    await auditorUser.enterMarkets([fixedLenderMaria.address], nextPoolId);

    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.8"),
        nextPoolId,
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
        nextPoolId,
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
      nextPoolId,
      applyMinFee(parseUnits("1"))
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      nextPoolId,
      applyMinFee(parseUnits("0.2"))
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      nextPoolId
    );

    await fixedLender.depositToSmartPool(parseUnits("0.2"));

    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.8"),
        nextPoolId,
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
      nextPoolId,
      applyMinFee(parseUnits("1"))
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      nextPoolId,
      applyMinFee(parseUnits("0.2"))
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      nextPoolId
    );

    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.8"),
        nextPoolId,
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
      nextPoolId,
      applyMinFee(parseUnits("1"))
    );

    await auditorUser.enterMarkets([fixedLenderMariaETH.address], nextPoolId);

    await fixedLender.depositToSmartPool(parseUnits("0.2"));

    await expect(
      fixedLenderMaria.borrowFromMaturityPool(
        parseUnits("0.8"),
        nextPoolId,
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
      nextPoolId,
      applyMinFee(parseUnits("1"))
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      nextPoolId,
      applyMinFee(parseUnits("0.2"))
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      nextPoolId
    );

    await fixedLenderMaria.depositToSmartPool(parseUnits("0.2"));

    const borrow = fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.3"),
      nextPoolId,
      applyMaxFee(parseUnits("0.3"))
    );

    await expect(borrow).to.not.be.reverted;
  });

  describe("GIVEN maria has plenty of ETH collateral", () => {
    let fixedLenderMaria: Contract;
    let underlyingTokenMaria: Contract;
    let underlyingTokenMariaETH: Contract;
    let fixedLenderMariaETH: Contract;
    beforeEach(async () => {
      fixedLenderMaria = fixedLender.connect(mariaUser);
      underlyingTokenMaria = underlyingToken.connect(mariaUser);
      fixedLenderMariaETH = fixedLenderETH.connect(mariaUser);
      underlyingTokenMariaETH = underlyingTokenETH.connect(mariaUser);
      await underlyingTokenMariaETH.approve(
        fixedLenderMariaETH.address,
        parseUnits("5")
      );
      await underlyingToken
        .connect(johnUser)
        .approve(fixedLender.address, parseUnits("10000"));
      await fixedLenderMariaETH.depositToMaturityPool(
        parseUnits("2"),
        nextPoolId,
        applyMinFee(parseUnits("2"))
      );
      await fixedLenderMariaETH.depositToMaturityPool(
        parseUnits("2"),
        laterPoolId,
        applyMinFee(parseUnits("2"))
      );
      await auditor
        .connect(mariaUser)
        .enterMarkets(
          [fixedLenderMaria.address, fixedLenderMariaETH.address],
          nextPoolId
        );
      await auditor
        .connect(mariaUser)
        .enterMarkets(
          [fixedLenderMaria.address, fixedLenderMariaETH.address],
          laterPoolId
        );
    });
    describe("AND GIVEN she deposits 1000DAI into the next two maturity pools AND 500 into the smart pool", () => {
      beforeEach(async () => {
        await underlyingTokenMaria.approve(
          fixedLender.address,
          parseUnits("5000")
        );
        await fixedLenderMaria.depositToMaturityPool(
          parseUnits("1000"),
          nextPoolId,
          applyMinFee(parseUnits("1000"))
        );
        await fixedLenderMaria.depositToMaturityPool(
          parseUnits("1000"),
          laterPoolId,
          applyMinFee(parseUnits("1000"))
        );
        await fixedLenderMaria.depositToSmartPool(parseUnits("500"));
      });
      describe("WHEN borrowing 1200 in the current maturity", () => {
        let maturityPool: any;
        let smartPool: any;
        beforeEach(async () => {
          await fixedLenderMaria.borrowFromMaturityPool(
            parseUnits("1200"),
            nextPoolId,
            applyMaxFee(parseUnits("1200"))
          );
          maturityPool = await fixedLenderMaria.maturityPools(nextPoolId);
          smartPool = await fixedLenderMaria.smartPool();
        });
        it("THEN all of the maturity pools funds are in use", async () => {
          expect(maturityPool.available).to.eq(parseUnits("0"));
        });
        it("AND 200 are borrowed from the smart pool", async () => {
          expect(smartPool.borrowed).to.eq(parseUnits("200"));
          expect(maturityPool.debt).to.eq(parseUnits("200"));
        });
        describe("AND borrowing 1100 in a later maturity ", () => {
          beforeEach(async () => {
            await fixedLenderMaria.borrowFromMaturityPool(
              parseUnits("1100"),
              laterPoolId,
              applyMaxFee(parseUnits("1100"))
            );
            maturityPool = await fixedLenderMaria.maturityPools(laterPoolId);
            smartPool = await fixedLenderMaria.smartPool();
          });
          it("THEN all of the maturity pools funds are in use", async () => {
            expect(maturityPool.available).to.eq(parseUnits("0"));
          });
          it("AND the later maturity owes 100 to the smart pool", async () => {
            expect(maturityPool.debt).to.eq(parseUnits("100"));
          });
          it("AND the smart pool has lent 300 (100 from the later maturity one, 200 from the first one)", async () => {
            expect(smartPool.borrowed).to.eq(parseUnits("300"));
          });
          describe("AND WHEN repaying 50 DAI in the later maturity", () => {
            beforeEach(async () => {
              await fixedLenderMaria.repayToMaturityPool(
                mariaUser.address,
                laterPoolId,
                parseUnits("50")
              );
              maturityPool = await fixedLenderMaria.maturityPools(laterPoolId);
              smartPool = await fixedLenderMaria.smartPool();
            });
            it("THEN only 1050 DAI are borrowed", async () => {
              expect(maturityPool.borrowed).to.eq(parseUnits("1050"));
            });
            it("AND the maturity pool doesnt have funds available", async () => {
              expect(maturityPool.available).to.eq(parseUnits("0"));
            });
            it("AND the maturity pool owes 50 to the smart pool", async () => {
              expect(maturityPool.debt).to.eq(parseUnits("50"));
            });
            it("AND the smart pool was repaid 50 DAI", async () => {
              expect(smartPool.borrowed).to.eq(parseUnits("250"));
            });
          });
          describe("AND WHEN john deposits 800 to the later maturity", () => {
            beforeEach(async () => {
              await fixedLender
                .connect(johnUser)
                .depositToMaturityPool(
                  parseUnits("800"),
                  laterPoolId,
                  applyMinFee(parseUnits("800"))
                );
              maturityPool = await fixedLenderMaria.maturityPools(laterPoolId);
              smartPool = await fixedLenderMaria.smartPool();
            });
            it("THEN 1100 DAI are still borrowed", async () => {
              expect(maturityPool.borrowed).to.eq(parseUnits("1100"));
            });
            it("AND the later maturity has 700 DAI available for borrowing", async () => {
              expect(maturityPool.available).to.eq(parseUnits("700"));
            });
            it("AND the later maturity owes nothing to the smart pool", async () => {
              expect(maturityPool.debt).to.eq(parseUnits("0"));
            });
            it("AND the smart pool was repaid 100 DAI from the later maturity, and is still owed 200 from the current one", async () => {
              expect(smartPool.borrowed).to.eq(parseUnits("200"));
            });
          });
        });
        describe("AND WHEN john deposits 100 to the same maturity", () => {
          beforeEach(async () => {
            await fixedLender
              .connect(johnUser)
              .depositToMaturityPool(
                parseUnits("100"),
                nextPoolId,
                applyMinFee(parseUnits("100"))
              );
            maturityPool = await fixedLenderMaria.maturityPools(nextPoolId);
            smartPool = await fixedLenderMaria.smartPool();
          });
          it("THEN 1200 DAI are still borrowed", async () => {
            expect(maturityPool.borrowed).to.eq(parseUnits("1200"));
          });
          it("AND the maturity pool still doesnt have funds available", async () => {
            expect(maturityPool.available).to.eq(parseUnits("0"));
          });
          it("AND the maturity pool owes 100 to the smart pool", async () => {
            expect(maturityPool.debt).to.eq(parseUnits("100"));
          });
          it("AND the smart pool was repaid the other 100 (is owed only 100)", async () => {
            expect(smartPool.borrowed).to.eq(parseUnits("100"));
          });
        });
        describe("AND WHEN john deposits 300 to the same maturity", () => {
          beforeEach(async () => {
            await fixedLender
              .connect(johnUser)
              .depositToMaturityPool(
                parseUnits("300"),
                nextPoolId,
                applyMinFee(parseUnits("300"))
              );
            maturityPool = await fixedLenderMaria.maturityPools(nextPoolId);
            smartPool = await fixedLenderMaria.smartPool();
          });
          it("THEN 1200 DAI are still borrowed", async () => {
            expect(maturityPool.borrowed).to.eq(parseUnits("1200"));
          });
          it("AND the maturity pool has 100 DAI available", async () => {
            expect(maturityPool.available).to.eq(parseUnits("100"));
          });
          it("AND the maturity pool owes nothing to the smart pool", async () => {
            expect(maturityPool.debt).to.eq(parseUnits("0"));
          });
          it("AND the smart pool was fully repaid", async () => {
            expect(smartPool.borrowed).to.eq(parseUnits("0"));
          });
        });
        describe("AND WHEN repaying 100 DAI", () => {
          beforeEach(async () => {
            await fixedLenderMaria.repayToMaturityPool(
              mariaUser.address,
              nextPoolId,
              parseUnits("100")
            );
            maturityPool = await fixedLenderMaria.maturityPools(nextPoolId);
            smartPool = await fixedLenderMaria.smartPool();
          });
          it("THEN only 1100 DAI are borrowed", async () => {
            expect(maturityPool.borrowed).to.eq(parseUnits("1100"));
          });
          it("AND the maturity pool doesnt have funds available", async () => {
            expect(maturityPool.available).to.eq(parseUnits("0"));
          });
          it("AND the maturity pool owes 100 to the smart pool", async () => {
            expect(maturityPool.debt).to.eq(parseUnits("100"));
          });
          it("AND the smart pool was repaid the other 100 (is owed only 100)", async () => {
            expect(smartPool.borrowed).to.eq(parseUnits("100"));
          });
        });
        describe("AND WHEN repaying 300 DAI", () => {
          beforeEach(async () => {
            await fixedLenderMaria.repayToMaturityPool(
              mariaUser.address,
              nextPoolId,
              parseUnits("300")
            );
            maturityPool = await fixedLenderMaria.maturityPools(nextPoolId);
            smartPool = await fixedLenderMaria.smartPool();
          });
          it("THEN only 900 DAI are borrowed", async () => {
            expect(maturityPool.borrowed).to.eq(parseUnits("900"));
          });
          it("AND the maturity pool has 100 DAI available", async () => {
            expect(maturityPool.available).to.eq(parseUnits("100"));
          });
          it("AND the maturity pool owes nothing to the smart pool", async () => {
            expect(maturityPool.debt).to.eq(parseUnits("0"));
          });
          it("AND the smart pool was fully repaid", async () => {
            expect(smartPool.borrowed).to.eq(parseUnits("0"));
          });
        });
        describe("AND WHEN repaying in full (1200 DAI)", () => {
          beforeEach(async () => {
            await fixedLenderMaria.repayToMaturityPool(
              mariaUser.address,
              nextPoolId,
              parseUnits("1200")
            );
            maturityPool = await fixedLenderMaria.maturityPools(nextPoolId);
            smartPool = await fixedLenderMaria.smartPool();
          });
          it("THEN zero DAI are borrowed", async () => {
            expect(maturityPool.borrowed).to.eq(parseUnits("0"));
          });
          it("AND the maturity pool has 1000 DAI available", async () => {
            expect(maturityPool.available).to.eq(parseUnits("1000"));
          });
          it("AND the maturity pool owes nothing to the smart pool", async () => {
            expect(maturityPool.debt).to.eq(parseUnits("0"));
          });
          it("AND the smart pool was fully repaid", async () => {
            expect(smartPool.borrowed).to.eq(parseUnits("0"));
          });
        });
      });
    });
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
      nextPoolId,
      applyMinFee(parseUnits("1"))
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      nextPoolId,
      applyMinFee(parseUnits("0.2"))
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      nextPoolId
    );

    await fixedLenderMaria.depositToSmartPool(parseUnits("0.2"));

    const borrow = fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.4"),
      nextPoolId,
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
      nextPoolId,
      applyMinFee(parseUnits("1"))
    );

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.2"),
      nextPoolId,
      applyMinFee(parseUnits("0.2"))
    );

    await auditorUser.enterMarkets(
      [fixedLenderMaria.address, fixedLenderMariaETH.address],
      nextPoolId
    );

    await fixedLenderMaria.depositToSmartPool(parseUnits("0.2"));

    const borrow = fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.4"),
      nextPoolId,
      applyMaxFee(parseUnits("0.4"))
    );

    await expect(borrow).to.not.be.reverted;

    let poolData = await fixedLender.maturityPools(nextPoolId);
    let debt = poolData[2];

    expect(debt).not.to.be.equal("0");

    await fixedLenderMaria.depositToMaturityPool(
      parseUnits("0.5"),
      nextPoolId,
      applyMinFee(parseUnits("0.5"))
    );

    poolData = await fixedLender.maturityPools(nextPoolId);
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
      nextPoolId,
      applyMinFee(parseUnits("1"))
    );

    await auditorUser.enterMarkets([fixedLenderMariaETH.address], nextPoolId);

    await fixedLender.depositToSmartPool(parseUnits("1"));
    await fixedLenderMaria.borrowFromMaturityPool(
      parseUnits("0.8"),
      nextPoolId,
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
              nextPoolId,
              applyMinFee(parseUnits("1800"))
            );
        });

        it("THEN the user receives 1800 on the maturity pool deposit", async () => {
          const supplied = (
            await fixedLender
              .connect(johnUser)
              .getAccountSnapshot(johnUser.address, nextPoolId)
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
                nextPoolId,
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
                  nextPoolId,
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
                  nextPoolId,
                  amountToTransfer
                );
            });

            it("THEN the user cancel its debt and succeeds", async () => {
              const borrowed = (
                await fixedLender
                  .connect(johnUser.address)
                  .getAccountSnapshot(johnUser.address, nextPoolId)
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
