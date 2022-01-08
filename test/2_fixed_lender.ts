import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import {
  errorGeneric,
  errorUnmatchedPool,
  applyMinFee,
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
    auditor = exactlyEnv.auditor;

    // From Owner to User
    await underlyingToken.transfer(mariaUser.address, parseUnits("100000"));
    await underlyingTokenETH.transfer(mariaUser.address, parseUnits("100000"));
    await underlyingToken.transfer(johnUser.address, parseUnits("100000"));

    await exactlyEnv.getInterestRateModel().setPenaltyRate(parseUnits("0.02"));
    exactlyEnv.switchWallet(mariaUser);
  });
  describe("small positions", () => {
    describe("WHEN depositing 2wei of a dai", () => {
      beforeEach(async () => {
        await exactlyEnv
          .getUnderlying("DAI")
          .connect(mariaUser)
          .approve(fixedLender.address, "10000");
        await exactlyEnv
          .getFixedLender("DAI")
          .connect(mariaUser)
          .depositToMaturityPool("2", nextPoolId, "0");
      });
      it("THEN the FixedLender registers a supply of 2 wei DAI for the user (exposed via getAccountSnapshot)", async () => {
        expect(
          (
            await fixedLender.getAccountSnapshot(mariaUser.address, nextPoolId)
          )[0]
        ).to.be.equal("2");
      });
      it("AND its not possible to borrow 2 wei of a dai", async () => {
        await expect(
          exactlyEnv
            .getFixedLender("DAI")
            .connect(mariaUser)
            .borrowFromMaturityPool("2", nextPoolId, "2")
        ).to.be.revertedWith(
          errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY)
        );
      });
      describe("AND WHEN borrowing 1 wei of DAI", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv
            .getFixedLender("DAI")
            .connect(mariaUser)
            .borrowFromMaturityPool("1", nextPoolId, "1");
          await tx;
        });
        it("THEN a BorrowFromMaturityPool event is emmitted", async () => {
          await expect(tx)
            .to.emit(exactlyEnv.getFixedLender("DAI"), "BorrowFromMaturityPool")
            .withArgs(mariaUser.address, "1", "0", nextPoolId);
        });
        it("AND a 1 wei of DAI borrow is registered", async () => {
          expect(
            await exactlyEnv.getFixedLender("DAI").getTotalMpBorrows(nextPoolId)
          ).to.equal("1");
        });
      });
    });
  });

  describe("WHEN depositing 100 DAI to a maturity pool (with a collateralization rate of 80%)", () => {
    let tx: any;
    beforeEach(async () => {
      tx = exactlyEnv.depositMP("DAI", nextPoolId, "100");
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
        exactlyEnv.withdrawMP("DAI", nextPoolId, "100")
      ).to.be.revertedWith(
        errorUnmatchedPool(PoolState.VALID, PoolState.MATURED)
      );
    });
    it("WHEN trying to borrow 90 DAI THEN it reverts with INSUFFICIENT_LIQUIDITY", async () => {
      await expect(
        exactlyEnv.borrowMP("DAI", nextPoolId, "90")
      ).to.be.revertedWith(errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY));
    });
    describe("AND WHEN depositing 50 DAI to the same maturity, as the same user", () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.depositMP("DAI", nextPoolId, "50");
        await tx;
      });
      it("THEN a DepositToMaturityPool event is emitted", async () => {
        await expect(tx).to.emit(fixedLender, "DepositToMaturityPool").withArgs(
          mariaUser.address,
          parseUnits("50"),
          parseUnits("0"), // commission, its zero with the mocked rate
          nextPoolId
        );
      });
      it("AND the FixedLender contract has a balance of 150 DAI", async () => {
        expect(await underlyingToken.balanceOf(fixedLender.address)).to.equal(
          parseUnits("150")
        );
      });
      it("AND the FixedLender registers a supply of 150 DAI for the user (exposed via getAccountSnapshot)", async () => {
        expect(
          (
            await fixedLender.getAccountSnapshot(mariaUser.address, nextPoolId)
          )[0]
        ).to.be.equal(parseUnits("150"));
      });
    });

    describe("WHEN borrowing 60 DAI from the same maturity", () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.borrowMP("DAI", nextPoolId, "60");
        await tx;
      });
      it("THEN a BorrowFromMaturityPool event is emmitted", async () => {
        await expect(tx)
          .to.emit(exactlyEnv.getFixedLender("DAI"), "BorrowFromMaturityPool")
          .withArgs(
            mariaUser.address,
            parseUnits("60"),
            parseUnits("0"),
            nextPoolId
          );
      });
      it("AND a 60 DAI borrow is registered", async () => {
        expect(
          await exactlyEnv.getFixedLender("DAI").getTotalMpBorrows(nextPoolId)
        ).to.equal(parseUnits("60"));
      });
      describe("AND WHEN fully repaying the debt", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.repayMP("DAI", nextPoolId, "60");
          await tx;
        });
        it("THEN a RepayToMaturityPool event is emitted", async () => {
          await expect(tx)
            .to.emit(exactlyEnv.getFixedLender("DAI"), "RepayToMaturityPool")
            .withArgs(
              mariaUser.address,
              mariaUser.address,
              parseUnits("0"),
              parseUnits("60"),
              nextPoolId
            );
        });
        it("AND WHEN withdrawing the collateral, THEN it reverts because the pool isnt mature yet", async () => {
          await expect(
            exactlyEnv.withdrawMP("DAI", nextPoolId, "100")
          ).to.be.revertedWith(
            errorUnmatchedPool(PoolState.VALID, PoolState.MATURED)
          );
        });
        describe("AND WHEN moving in time to maturity AND withdrawing the collateral", () => {
          beforeEach(async () => {
            await exactlyEnv.moveInTime(nextPoolId);
            await exactlyEnv.withdrawMP("DAI", nextPoolId, "100");
          });
          // TODO tests for partial/excessive withdrawal?
          it("THEN the collateral is returned to Maria", async () => {
            expect(await underlyingToken.balanceOf(mariaUser.address)).to.eq(
              parseUnits("100000")
            );
            expect(await underlyingToken.balanceOf(fixedLender.address)).to.eq(
              parseUnits("0")
            );
          });
        });
      });
      describe("GIVEN the pool matures", () => {
        beforeEach(async () => {
          await exactlyEnv.moveInTime(nextPoolId);
        });
        it("WHEN trying to withdraw an amount of zero THEN it reverts", async () => {
          await expect(
            exactlyEnv.withdrawMP("DAI", nextPoolId, "0")
          ).to.be.revertedWith(errorGeneric(ProtocolError.REDEEM_CANT_BE_ZERO));
        });
        it("WHEN trying to withdraw the entire position (100 DAI) without repaying first THEN it reverts with INSUFFICIENT_LIQUIDITY", async () => {
          await expect(
            exactlyEnv.withdrawMP("DAI", nextPoolId, "100")
          ).to.be.revertedWith(
            errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY)
          );
        });
        it("AND WHEN trying to withdraw a small amount that doesnt cause a shortfall (10 DAI, should move collateralization from 60% to 66%) without repaying first THEN it is allowed", async () => {
          await expect(exactlyEnv.withdrawMP("DAI", nextPoolId, "10")).to.not.be
            .reverted;
        });
      });

      describe("AND WHEN partially (40DAI, 66%) repaying the debt", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.repayMP("DAI", nextPoolId, "40");
          await tx;
        });
        it("THEN a RepayToMaturityPool event is emitted", async () => {
          await expect(tx)
            .to.emit(exactlyEnv.getFixedLender("DAI"), "RepayToMaturityPool")
            .withArgs(
              mariaUser.address,
              mariaUser.address,
              parseUnits("0"),
              parseUnits("40"),
              nextPoolId
            );
        });
        it("AND Maria still owes 20 DAI", async () => {
          const [, amountOwed] = await exactlyEnv
            .getFixedLender("DAI")
            .getAccountSnapshot(mariaUser.address, nextPoolId);

          expect(amountOwed).to.equal(parseUnits("20"));
        });

        describe("AND WHEN moving in time to 1 day after maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.moveInTime(nextPoolId + exaTime.ONE_DAY);
          });
          it("THEN Maria owes (getAccountSnapshot) 20 DAI of principal + (20*0.02 == 0.04 ) DAI of late payment penalties", async () => {
            const [, amountOwed] = await exactlyEnv
              .getFixedLender("DAI")
              .getAccountSnapshot(mariaUser.address, nextPoolId);

            expect(amountOwed).to.equal(parseUnits("20.4"));
          });
          describe("AND WHEN repaying the rest of the 20.4 owed DAI", () => {
            beforeEach(async () => {
              await exactlyEnv.repayMP("DAI", nextPoolId, "20.4");
            });
            it("THEN all debt is repaid", async () => {
              const [, amountOwed] = await exactlyEnv
                .getFixedLender("DAI")
                .getAccountSnapshot(mariaUser.address, nextPoolId);

              expect(amountOwed).to.equal(0);
            });
          });
        });
      });
    });

    describe("AND WHEN moving in time to maturity AND withdrawing from the maturity pool", () => {
      let tx: any;
      beforeEach(async () => {
        await exactlyEnv.moveInTime(nextPoolId);
        tx = await exactlyEnv.withdrawMP("DAI", nextPoolId, "100");
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
          .withArgs(mariaUser.address, parseUnits("100"), nextPoolId);
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
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.INVALID, PoolState.VALID)
        );
      });
      it("WHEN trying to borrow to an invalid pool THEN it reverts ", async () => {
        await expect(
          exactlyEnv.borrowMP("DAI", exaTime.invalidPoolID(), "3", "3")
        ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
      });
    });
    describe("actions enabled/disabled at different pool stages when Smart Pool has liquidity", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(owner);
        // We add liquidity to the smart pool for the maturity pool
        // to be able to borrow from it. It can borrow up to 1/12
        // of the total supply of the Smart Pool
        await exactlyEnv.depositSP("DAI", "100000");
        exactlyEnv.switchWallet(mariaUser);
      });

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

      it("WHEN trying to borrow from an already-matured pool THEN it reverts", async () => {
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

      await exactlyEnv.depositMP("DAI", nextPoolId, "1");
      await exactlyEnv.enterMarkets(["DAI"], nextPoolId);
    });
    it("WHEN trying to borrow 0.8 DAI with a max amount of debt of 0.8 DAI, THEN it reverts with TOO_MUCH_SLIPPAGE", async () => {
      await expect(
        exactlyEnv.borrowMP("DAI", nextPoolId, "0.8", "0.8")
      ).to.be.revertedWith(errorGeneric(ProtocolError.TOO_MUCH_SLIPPAGE));
    });

    it("WHEN trying to deposit 100 DAI with a minimum required amount to be received of 103, THEN 102 are received instead AND the transaction reverts with TOO_MUCH_SLIPPAGE", async () => {
      let tx = exactlyEnv.depositMP("DAI", nextPoolId, "100", "103");
      await expect(tx).to.be.revertedWith(
        errorGeneric(ProtocolError.TOO_MUCH_SLIPPAGE)
      );
    });
  });

  describe("GIVEN Maria has 10ETH collateral", () => {
    beforeEach(async () => {
      await exactlyEnv.depositMP("ETH", nextPoolId, "10");
      await exactlyEnv.enterMarkets(["ETH"], nextPoolId);
    });
    it("WHEN Maria tries to borrow 50 DAI on an empty maturity, THEN it fails with INSUFFICIENT_PROTOCOL_LIQUIDITY", async () => {
      await expect(
        exactlyEnv.borrowMP("DAI", nextPoolId, "10")
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
      );
    });
    describe("AND John deposited 2400 DAI to the smart pool", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(johnUser);
        await exactlyEnv.depositSP("DAI", "2400");
        exactlyEnv.switchWallet(mariaUser);
      });
      it("WHEN Maria tries to borrow 300 DAI, THEN it fails with INSUFFICIENT_PROTOCOL_LIQUIDITY", async () => {
        await expect(
          exactlyEnv.borrowMP("DAI", nextPoolId, "300")
        ).to.be.revertedWith(
          errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
        );
      });
      it("WHEN Maria tries to borrow 150 DAI, THEN it succeeds", async () => {
        await expect(exactlyEnv.borrowMP("DAI", nextPoolId, "150")).to.not.be
          .reverted;
      });
    });
    describe("AND John deposited 100 DAI to maturity", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(johnUser);
        await exactlyEnv.depositMP("DAI", nextPoolId, "100");
        exactlyEnv.switchWallet(mariaUser);
      });
      it("WHEN Maria tries to borrow 150 DAI, THEN it fails with INSUFFICIENT_PROTOCOL_LIQUIDITY", async () => {
        await expect(
          exactlyEnv.borrowMP("DAI", nextPoolId, "150")
        ).to.be.revertedWith(
          errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
        );
      });
      describe("AND John deposited 1200 DAI to the smart pool", () => {
        beforeEach(async () => {
          exactlyEnv.switchWallet(johnUser);
          await exactlyEnv.depositSP("DAI", "1200");
          exactlyEnv.switchWallet(mariaUser);
        });
        it("WHEN Maria tries to borrow 300 DAI, THEN it fails with INSUFFICIENT_PROTOCOL_LIQUIDITY", async () => {
          await expect(
            exactlyEnv.borrowMP("DAI", nextPoolId, "300")
          ).to.be.revertedWith(
            errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
          );
        });
        it("WHEN Maria tries to borrow 200 DAI, THEN it succeeds", async () => {
          await expect(exactlyEnv.borrowMP("DAI", nextPoolId, "200")).to.not.be
            .reverted;
        });
        it("WHEN Maria tries to borrow 150 DAI, THEN it succeeds", async () => {
          await expect(exactlyEnv.borrowMP("DAI", nextPoolId, "150")).to.not.be
            .reverted;
        });
      });
    });
  });

  describe("GIVEN maria has plenty of ETH collateral", () => {
    beforeEach(async () => {
      await exactlyEnv.depositMP("ETH", nextPoolId, "2");
      await exactlyEnv.depositMP("ETH", laterPoolId, "2");
      await exactlyEnv.enterMarkets(["DAI", "ETH"], nextPoolId);
      await exactlyEnv.enterMarkets(["DAI", "ETH"], laterPoolId);
    });
    describe("AND GIVEN she deposits 1000DAI into the next two maturity pools AND 500 * 12 = 6000 into the smart pool", () => {
      beforeEach(async () => {
        await exactlyEnv.depositMP("DAI", nextPoolId, "1000");
        await exactlyEnv.depositMP("DAI", laterPoolId, "1000");
        await exactlyEnv.depositSP("DAI", "6000");
      });
      describe("WHEN borrowing 1200 in the current maturity", () => {
        let maturityPool: any;
        let smartPool: any;
        beforeEach(async () => {
          await exactlyEnv.borrowMP("DAI", nextPoolId, "1200");
          maturityPool = await fixedLender.maturityPools(nextPoolId);
          smartPool = await exactlyEnv.smartPoolState("DAI");
        });
        it("THEN all of the maturity pools funds are in use", async () => {
          expect(maturityPool.borrowed).to.gt(maturityPool.supplied);
        });
        it("AND 200 are borrowed from the smart pool", async () => {
          expect(smartPool.borrowed).to.eq(parseUnits("200"));
          expect(maturityPool.suppliedSP).to.eq(parseUnits("200"));
        });
        it("AND WHEN trying to withdraw 300 ==(500 available, 200 borrowed to MP) from the smart pool, THEN it succeeds", async () => {
          await expect(exactlyEnv.withdrawSP("DAI", "300")).to.not.be.reverted;
        });
        it("AND WHEN trying to withdraw 5900 >(6000 total, 200 borrowed to MP) from the smart pool, THEN it reverts because 100 of those 5900 are still lent to the maturity pool", async () => {
          await expect(exactlyEnv.withdrawSP("DAI", "5900")).to.be.revertedWith(
            errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
          );
        });
        describe("AND borrowing 1100 in a later maturity ", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", laterPoolId, "1100");
            maturityPool = await fixedLender.maturityPools(laterPoolId);
            smartPool = await exactlyEnv.smartPoolState("DAI");
          });
          it("THEN all of the maturity pools funds are in use", async () => {
            expect(maturityPool.borrowed).to.gt(maturityPool.supplied);
          });
          it("THEN the later maturity owes 100 to the smart pool", async () => {
            expect(maturityPool.suppliedSP).to.eq(parseUnits("100"));
          });
          it("THEN the smart pool has lent 300 (100 from the later maturity one, 200 from the first one)", async () => {
            expect(smartPool.borrowed).to.eq(parseUnits("300"));
          });
          describe("AND WHEN repaying 50 DAI in the later maturity", () => {
            beforeEach(async () => {
              await exactlyEnv.repayMP("DAI", laterPoolId, "50");
              maturityPool = await fixedLender.maturityPools(laterPoolId);
              smartPool = await exactlyEnv.smartPoolState("DAI");
            });
            it("THEN 1050 DAI are borrowed", async () => {
              expect(maturityPool.borrowed).to.eq(parseUnits("1050"));
            });
            it("THEN the maturity pool doesnt have funds available", async () => {
              expect(maturityPool.borrowed).to.gt(maturityPool.supplied);
            });
            it("THEN the maturity pool still owes 100 to the smart pool", async () => {
              expect(maturityPool.suppliedSP).to.eq(parseUnits("100"));
            });
            it("THEN the smart pool was NOT repaid 50 DAI", async () => {
              expect(smartPool.borrowed).to.eq(parseUnits("300"));
            });
          });
          describe("AND WHEN john deposits 800 to the later maturity", () => {
            beforeEach(async () => {
              exactlyEnv.switchWallet(johnUser);
              await exactlyEnv.depositMP("DAI", laterPoolId, "800");
              maturityPool = await fixedLender.maturityPools(laterPoolId);
              smartPool = await exactlyEnv.smartPoolState("DAI");
            });
            it("THEN 1100 DAI are still borrowed", async () => {
              expect(maturityPool.borrowed).to.eq(parseUnits("1100"));
            });
            it("THEN the later maturity has 700 DAI available for borrowing", async () => {
              expect(maturityPool.supplied.sub(maturityPool.borrowed)).to.eq(
                parseUnits("700")
              );
            });
            it("THEN the later maturity still owes 100 DAI to the smart pool", async () => {
              expect(maturityPool.suppliedSP).to.eq(parseUnits("100"));
            });
            it("THEN the smart pool was NOT repaid 100 DAI from the later maturity, and is still owed 300 from the current one", async () => {
              expect(smartPool.borrowed).to.eq(parseUnits("300"));
            });
          });
        });
        describe("AND WHEN john deposits 100 to the same maturity", () => {
          beforeEach(async () => {
            exactlyEnv.switchWallet(johnUser);
            await exactlyEnv.depositMP("DAI", nextPoolId, "100");
            maturityPool = await fixedLender.maturityPools(nextPoolId);
            smartPool = await exactlyEnv.smartPoolState("DAI");
          });
          it("THEN 1200 DAI are still borrowed", async () => {
            expect(maturityPool.borrowed).to.eq(parseUnits("1200"));
          });
          it("THEN the maturity pool still doesnt have funds available", async () => {
            expect(maturityPool.borrowed).to.gt(maturityPool.supplied);
          });
          it("THEN the maturity pool still owes 200 to the smart pool", async () => {
            expect(maturityPool.suppliedSP).to.eq(parseUnits("200"));
          });
          it("THEN the smart pool was NOT repaid the other 100 (is owed still 200)", async () => {
            expect(smartPool.borrowed).to.eq(parseUnits("200"));
          });
        });
        describe("AND WHEN john deposits 300 to the same maturity", () => {
          beforeEach(async () => {
            exactlyEnv.switchWallet(johnUser);
            await exactlyEnv.depositMP("DAI", nextPoolId, "300");
            maturityPool = await fixedLender.maturityPools(nextPoolId);
            smartPool = await exactlyEnv.smartPoolState("DAI");
          });
          it("THEN 1200 DAI are still borrowed", async () => {
            expect(maturityPool.borrowed).to.eq(parseUnits("1200"));
          });
          it("THEN the maturity pool has 100 DAI available", async () => {
            expect(maturityPool.supplied.sub(maturityPool.borrowed)).to.eq(
              parseUnits("100")
            );
          });
          it("THEN the maturity pool still owes 200 to the smart pool", async () => {
            expect(maturityPool.suppliedSP).to.eq(parseUnits("200"));
          });
        });
        describe("AND WHEN repaying 100 DAI", () => {
          beforeEach(async () => {
            await exactlyEnv.repayMP("DAI", nextPoolId, "100");
            maturityPool = await fixedLender.maturityPools(nextPoolId);
            smartPool = await exactlyEnv.smartPoolState("DAI");
          });
          it("THEN 1100 DAI are still borrowed", async () => {
            expect(maturityPool.borrowed).to.eq(parseUnits("1100"));
          });
          it("THEN the maturity pool doesnt have funds available", async () => {
            expect(maturityPool.borrowed).to.gt(maturityPool.supplied);
          });
          it("THEN the maturity pool still owes 200 to the smart pool", async () => {
            expect(maturityPool.suppliedSP).to.eq(parseUnits("200"));
          });
        });
        describe("AND WHEN repaying 300 DAI", () => {
          beforeEach(async () => {
            await exactlyEnv.repayMP("DAI", nextPoolId, "300");
            maturityPool = await fixedLender.maturityPools(nextPoolId);
            smartPool = await exactlyEnv.smartPoolState("DAI");
          });
          it("THEN 900 DAI are still borrowed", async () => {
            expect(maturityPool.borrowed).to.eq(parseUnits("900"));
          });
          it("THEN the maturity pool has 100 DAI available", async () => {
            expect(maturityPool.supplied.sub(maturityPool.borrowed)).to.eq(
              parseUnits("100")
            );
          });
          it("THEN the maturity pool still owes 200 to the smart pool", async () => {
            expect(maturityPool.suppliedSP).to.eq(parseUnits("200"));
          });
        });
        describe("AND WHEN repaying in full (1200 DAI)", () => {
          beforeEach(async () => {
            await exactlyEnv.repayMP("DAI", nextPoolId, "1200");
            maturityPool = await fixedLender.maturityPools(nextPoolId);
            smartPool = await exactlyEnv.smartPoolState("DAI");
          });
          it("THEN the maturity pool has 1000 DAI available", async () => {
            expect(maturityPool.supplied.sub(maturityPool.borrowed)).to.eq(
              parseUnits("1000")
            );
          });
        });
      });
    });
  });

  describe("Transfers with Commissions", () => {
    describe("GIVEN an underlying token with 10% comission", () => {
      beforeEach(async () => {
        await underlyingToken.setCommission(parseUnits("0.1"));
        await underlyingToken.transfer(johnUser.address, parseUnits("10000"));
      });

      describe("WHEN depositing 2000 DAI on a maturity pool", () => {
        beforeEach(async () => {
          exactlyEnv.switchWallet(johnUser);
          await exactlyEnv.depositMP("DAI", nextPoolId, "2000", "1800");
          exactlyEnv.switchWallet(mariaUser);
        });

        it("THEN the user receives 1800 on the maturity pool deposit", async () => {
          const supplied = (
            await fixedLender
              .connect(johnUser)
              .getAccountSnapshot(johnUser.address, nextPoolId)
          )[0];
          expect(supplied).to.eq(parseUnits("1800"));
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
            let tx: any;
            beforeEach(async () => {
              exactlyEnv.switchWallet(johnUser);
              tx = exactlyEnv.repayMP("DAI", nextPoolId, "1100");
            });

            it("THEN the transaction is reverted TOO_MUCH_REPAY_TRANSFER", async () => {
              await expect(tx).to.be.revertedWith(
                errorGeneric(ProtocolError.TOO_MUCH_REPAY_TRANSFER)
              );
            });
          });

          describe("AND WHEN repaying with 10% commission", () => {
            beforeEach(async () => {
              exactlyEnv.switchWallet(johnUser);
              await exactlyEnv.repayMP("DAI", nextPoolId, "1000");
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
