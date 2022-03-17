import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ExaTime, MaturityPoolState } from "./exactlyUtils";
import { PoolAccountingEnv } from "./poolAccountingEnv";

const { provider } = ethers;

describe("PoolAccounting", () => {
  let laura: SignerWithAddress;
  let tina: SignerWithAddress;
  let poolAccountingEnv: PoolAccountingEnv;
  let poolAccountingHarness: Contract;
  let mockedInterestRateModel: Contract;
  const exaTime = new ExaTime();
  let snapshot: any;
  const nextPoolID = exaTime.nextPoolID() + 7 * exaTime.ONE_DAY; // we add 7 days so we make sure we are far from the previous timestamp blocks

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
    [, laura, tina] = await ethers.getSigners();
    poolAccountingEnv = await PoolAccountingEnv.create();
    poolAccountingHarness = poolAccountingEnv.poolAccountingHarness;
    mockedInterestRateModel = poolAccountingEnv.mockedInterestRateModel;
  });

  describe("function calls not originating from the FixedLender contract", () => {
    it("WHEN invoking borrowMP NOT from the FixedLender, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        poolAccountingHarness.borrowMP(0, laura.address, 0, 0, 0, 0)
      ).to.be.revertedWith("NotFixedLender()");
    });

    it("WHEN invoking depositMP NOT from the FixedLender, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        poolAccountingHarness.depositMP(0, laura.address, 0, 0)
      ).to.be.revertedWith("NotFixedLender()");
    });

    it("WHEN invoking repayMP NOT from the FixedLender, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        poolAccountingHarness.repayMP(0, laura.address, 0, 0)
      ).to.be.revertedWith("NotFixedLender()");
    });

    it("WHEN invoking withdrawMP NOT from the FixedLender, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        poolAccountingHarness.withdrawMP(0, laura.address, 0, 0, 0, 0)
      ).to.be.revertedWith("NotFixedLender()");
    });
  });
  describe("setPenaltyRate", () => {
    it("WHEN calling setPenaltyRate, THEN the penaltyRate should be updated", async () => {
      await poolAccountingHarness.setPenaltyRate(parseUnits("0.04"));
      expect(await poolAccountingHarness.penaltyRate()).to.be.equal(
        parseUnits("0.04")
      );
    });
    it("WHEN calling setPenaltyRate, THEN it should emit UpdatedPenaltyRate event", async () => {
      await expect(
        await poolAccountingHarness.setPenaltyRate(parseUnits("0.04"))
      )
        .to.emit(poolAccountingHarness, "UpdatedPenaltyRate")
        .withArgs(parseUnits("0.04"));
    });
    it("WHEN calling setPenaltyRate from a regular (non-admin) user, THEN it reverts with an AccessControl error", async () => {
      await expect(
        poolAccountingHarness.connect(laura).setPenaltyRate(parseUnits("0.04"))
      ).to.be.revertedWith("AccessControl");
    });
  });

  describe("setProtocolSpreadFee", () => {
    it("WHEN calling setProtocolSpreadFee, THEN the protocolSpreadFee should be updated", async () => {
      await poolAccountingHarness.setProtocolSpreadFee(parseUnits("0.04"));
      expect(await poolAccountingHarness.protocolSpreadFee()).to.be.equal(
        parseUnits("0.04")
      );
    });
    it("WHEN calling setProtocolSpreadFee, THEN it should emit UpdatedProtocolSpreadFee event", async () => {
      await expect(
        await poolAccountingHarness.setProtocolSpreadFee(parseUnits("0.04"))
      )
        .to.emit(poolAccountingHarness, "UpdatedProtocolSpreadFee")
        .withArgs(parseUnits("0.04"));
    });
    it("WHEN calling setProtocolSpreadFee from a regular (non-admin) user, THEN it reverts with an AccessControl error", async () => {
      await expect(
        poolAccountingHarness
          .connect(laura)
          .setProtocolSpreadFee(parseUnits("0.04"))
      ).to.be.revertedWith("AccessControl");
    });
  });

  describe("GIVEN a depositMP with an amount of 10000 (0 fees earned)", () => {
    const sixDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 5;
    let depositAmount: any;
    let withdrawAmount: any;
    let borrowAmount: any;
    let borrowFees: any;
    let returnValues: any;
    let repayAmount: any;
    let mpUserSuppliedAmount: any;
    let mpUserBorrowedAmount: any;
    let mp: any;
    const maturityPoolState: MaturityPoolState = {
      borrowFees: parseUnits("0"),
      earningsTreasury: parseUnits("0"),
      earningsUnassigned: parseUnits("0"),
      earningsSP: parseUnits("0"),
      earningsMP: parseUnits("0"),
      earningsDiscounted: parseUnits("0"),
    };

    beforeEach(async () => {
      depositAmount = "10000";

      poolAccountingEnv.switchWallet(laura);
      await poolAccountingEnv.moveInTime(sixDaysToMaturity);
      await poolAccountingEnv.depositMP(nextPoolID, depositAmount);

      returnValues = await poolAccountingHarness.returnValues();
      mp = await poolAccountingHarness.maturityPools(nextPoolID);
      mpUserSuppliedAmount = await poolAccountingHarness.mpUserSuppliedAmount(
        nextPoolID,
        laura.address
      );
    });
    it("THEN borrowed equals 0", async () => {
      expect(mp.borrowed).to.eq(parseUnits("0"));
    });
    it("THEN supplied equals to depositedAmount", async () => {
      expect(mp.supplied).to.eq(parseUnits(depositAmount));
    });
    it("THEN suppliedSP is 0", async () => {
      expect(mp.suppliedSP).to.eq(parseUnits("0"));
    });
    it("THEN earningsUnassigned are 0", async () => {
      expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
    });
    it("THEN lastAccrue is 6 days to maturity", async () => {
      expect(mp.lastAccrue).to.eq(sixDaysToMaturity);
    });
    it("THEN the mpUserSuppliedAmount is correctly updated", async () => {
      expect(mpUserSuppliedAmount[0]).to.be.eq(
        parseUnits(depositAmount.toString())
      );
      expect(mpUserSuppliedAmount[1]).to.be.eq(parseUnits("0"));
    });
    it("THEN the earningsSP returned are 0", async () => {
      expect(returnValues.earningsSP).to.eq(parseUnits("0"));
    });
    it("THEN the currentTotalDeposit returned is equal to the amount (no fees earned)", async () => {
      expect(returnValues.currentTotalDeposit).to.eq(parseUnits(depositAmount));
    });

    describe("AND GIVEN a borrowMP with an amount of 5000 (250 charged in fees to treasury) (4 days to go)", () => {
      const fourDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 4;
      beforeEach(async () => {
        borrowAmount = 5000;
        borrowFees = 250;
        await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await poolAccountingEnv.moveInTime(fourDaysToMaturity);
        await poolAccountingEnv.borrowMP(
          nextPoolID,
          borrowAmount.toString(),
          (borrowAmount + borrowFees).toString()
        );

        mpUserBorrowedAmount = await poolAccountingHarness.mpUserBorrowedAmount(
          nextPoolID,
          laura.address
        );
        returnValues = await poolAccountingHarness.returnValues();
        mp = await poolAccountingHarness.maturityPools(nextPoolID);
        maturityPoolState.earningsTreasury = returnValues.earningsTreasury;
        maturityPoolState.borrowFees = returnValues.totalOwedNewBorrow.sub(
          parseUnits(borrowAmount.toString())
        );
      });
      it("THEN borrowed is the just borrowed amount", async () => {
        expect(mp.borrowed).to.eq(parseUnits(borrowAmount.toString()));
      });
      it("THEN supplied is the just deposited amount", async () => {
        expect(mp.supplied).to.eq(parseUnits(depositAmount));
      });
      it("THEN suppliedSP is equal to 0", async () => {
        expect(mp.suppliedSP).to.eq(parseUnits("0"));
      });
      it("THEN earningsUnassigned are 0", async () => {
        expect(mp.earningsUnassigned).to.eq(0);
      });
      it("THEN lastAccrue is 4 days to maturity", async () => {
        expect(mp.lastAccrue).to.eq(fourDaysToMaturity);
      });
      it("THEN the mpUserBorrowedAmount is correctly updated", async () => {
        expect(mpUserBorrowedAmount[0]).to.be.eq(
          parseUnits(borrowAmount.toString())
        );
        expect(mpUserBorrowedAmount[1]).to.be.eq(
          parseUnits(borrowFees.toString())
        );
      });
      it("THEN the earningsTreasury returned are 5000 x 0,05 (5%)", async () => {
        expect(returnValues.earningsTreasury).to.eq(
          parseUnits(borrowFees.toString()) // 5000 x 0,05 (5%)
        );
      });
      it("THEN the earningsSP returned are 0", async () => {
        expect(returnValues.earningsSP).to.eq(parseUnits("0"));
      });
      it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
        expect(returnValues.totalOwedNewBorrow).to.eq(
          parseUnits((borrowAmount + borrowFees).toString())
        );
      });

      describe("AND GIVEN another borrowMP call with an amount of 5000 (250 charged in fees to treasury) (3 days to go)", () => {
        const threeDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 3;
        beforeEach(async () => {
          borrowAmount = 5000;
          borrowFees = 250;

          await poolAccountingEnv.moveInTime(threeDaysToMaturity);
          await poolAccountingEnv.borrowMP(
            nextPoolID,
            borrowAmount.toString(),
            (borrowAmount + borrowFees).toString()
          );

          mpUserBorrowedAmount =
            await poolAccountingHarness.mpUserBorrowedAmount(
              nextPoolID,
              laura.address
            );
          returnValues = await poolAccountingHarness.returnValues();
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
          maturityPoolState.borrowFees = maturityPoolState.borrowFees.add(
            returnValues.totalOwedNewBorrow.sub(
              parseUnits(borrowAmount.toString())
            )
          );
          maturityPoolState.earningsTreasury =
            maturityPoolState.earningsTreasury.add(
              returnValues.totalOwedNewBorrow.sub(
                parseUnits(borrowAmount.toString())
              )
            );
          maturityPoolState.earningsUnassigned = parseUnits("0");
        });
        it("THEN borrowed is 2x the previously borrow amount", async () => {
          expect(mp.borrowed).to.eq(parseUnits((borrowAmount * 2).toString()));
        });
        it("THEN supplied is the one depositedAmount", async () => {
          expect(mp.supplied).to.eq(parseUnits(depositAmount.toString()));
        });
        it("THEN suppliedSP is 0", async () => {
          expect(mp.suppliedSP).to.eq(parseUnits("0"));
        });
        it("THEN earningsUnassigned are 0", async () => {
          expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
        });
        it("THEN the lastAccrue is 3 days to maturity", async () => {
          expect(mp.lastAccrue).to.eq(threeDaysToMaturity);
        });
        it("THEN the borrow + fees are correctly added to the mpUserBorrowedAmount", async () => {
          expect(mpUserBorrowedAmount[0]).to.be.eq(
            parseUnits((borrowAmount * 2).toString())
          );
          expect(mpUserBorrowedAmount[1]).to.be.eq(
            parseUnits((borrowFees * 2).toString())
          );
        });
        it("THEN the earningsTreasury returned are 250", async () => {
          expect(returnValues.earningsTreasury).to.eq(
            parseUnits(borrowFees.toString())
          );
        });
        it("THEN the earningsSP returned are 0", async () => {
          expect(returnValues.earningsSP).to.eq(parseUnits("0"));
        });
        it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
          expect(returnValues.totalOwedNewBorrow).to.eq(
            parseUnits((borrowAmount + borrowFees).toString())
          );
        });
        it("THEN the borrow fees are equal to all earnings distributed", async () => {
          expect(maturityPoolState.borrowFees).to.eq(
            poolAccountingEnv.getAllEarnings(maturityPoolState)
          );
        });

        describe("AND GIVEN another borrowMP call with an amount of 5000 (250 charged in fees to unassigned) (2 days to go)", () => {
          const twoDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 2;
          beforeEach(async () => {
            borrowAmount = 5000;
            borrowFees = 250;

            await poolAccountingEnv.moveInTime(twoDaysToMaturity);
            await poolAccountingEnv.borrowMP(
              nextPoolID,
              borrowAmount.toString(),
              (borrowAmount + borrowFees).toString()
            );

            returnValues = await poolAccountingHarness.returnValues();
            mp = await poolAccountingHarness.maturityPools(nextPoolID);
            maturityPoolState.borrowFees = maturityPoolState.borrowFees.add(
              returnValues.totalOwedNewBorrow.sub(
                parseUnits(borrowAmount.toString())
              )
            );
            maturityPoolState.earningsUnassigned =
              maturityPoolState.earningsUnassigned.add(mp.earningsUnassigned);
          });
          it("THEN borrowed is 3x the borrowAmount", async () => {
            expect(mp.borrowed).to.eq(
              parseUnits((borrowAmount * 3).toString())
            );
          });
          it("THEN supplied is 1x depositAmount", async () => {
            expect(mp.supplied).to.eq(parseUnits(depositAmount));
          });
          it("THEN suppliedSP is borrowAmount", async () => {
            expect(mp.suppliedSP).to.eq(parseUnits(borrowAmount.toString()));
          });
          it("THEN earningsUnassigned are 250", async () => {
            expect(mp.earningsUnassigned).to.eq(
              parseUnits(borrowFees.toString())
            );
          });
          it("THEN lastAccrue is 2 days to maturity", async () => {
            expect(mp.lastAccrue).to.eq(twoDaysToMaturity);
          });
          it("THEN the earningsSP returned are 0", async () => {
            expect(returnValues.earningsSP).to.eq(parseUnits("0"));
          });
          it("THEN the earningsTreasury returned are 0", async () => {
            expect(returnValues.earningsTreasury).to.eq(parseUnits("0"));
          });
          it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
            expect(returnValues.totalOwedNewBorrow).to.eq(
              parseUnits((borrowAmount + borrowFees).toString())
            );
          });
          it("THEN the borrow fees are equal to all earnings distributed", async () => {
            expect(maturityPoolState.borrowFees).to.eq(
              poolAccountingEnv.getAllEarnings(maturityPoolState)
            );
          });

          describe("AND GIVEN a repayMP with an amount of 15750 (total EARLY repayment) (1 day to go)", () => {
            const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY * 1;
            let mp: any;
            beforeEach(async () => {
              repayAmount = 15750;
              await poolAccountingEnv.moveInTime(oneDayToMaturity);
              await poolAccountingEnv.repayMP(
                nextPoolID,
                repayAmount.toString()
              );

              mpUserBorrowedAmount =
                await poolAccountingHarness.mpUserBorrowedAmount(
                  nextPoolID,
                  laura.address
                );
              returnValues = await poolAccountingHarness.returnValues();
              mp = await poolAccountingHarness.maturityPools(nextPoolID);
            });

            it("THEN borrowed field is updated correctly and is 0", async () => {
              // debtCovered=17325*15750/17325=15750
              // principal of 15750 => 15000 (following ratio principal-fee of 15000 and 750)
              // borrowed original (15000) - 15000 = 0
              expect(mp.borrowed).to.be.eq(0);
            });

            it("THEN supplies are correctly updated", async () => {
              expect(mp.supplied).to.eq(
                parseUnits(depositAmount.toString()) // 10k
              );
              expect(mp.suppliedSP).to.eq(parseUnits("0"));
            });
            it("THEN the debtCovered was equal to full repayAmount", async () => {
              // debtCovered=5775*5250/5775=5250
              expect(returnValues.debtCovered).to.eq(parseUnits("15750"));
            });
            it("THEN the mpUserBorrowedAmount position is 0", async () => {
              expect(mpUserBorrowedAmount[0]).to.be.eq(0);
              expect(mpUserBorrowedAmount[1]).to.be.eq(0);
            });
            it("THEN earningsSP returned 125", async () => {
              expect(returnValues.earningsSP).to.eq(parseUnits("125")); // earningsUnassigned were 250, then 1 day passed so earningsSP accrued half
            });
            it("THEN the earningsTreasury returned is 0", async () => {
              expect(returnValues.earningsTreasury).to.eq(0);
            });
            it("THEN the actualRepayAmount returned is 15750 - 125", async () => {
              // Takes all the unassignedEarnings
              // first 500 were taken by the treasury
              // then 125 was accrued and earned by the SP
              // then the repay takes the rest as a discount
              expect(returnValues.actualRepayAmount).to.eq(
                parseUnits((repayAmount - 125).toString())
              );
            });
          });

          describe("AND GIVEN a repayMP with an amount of 8000 (partial EARLY repayment) (1 day to go)", () => {
            const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY * 1;
            let mp: any;
            beforeEach(async () => {
              repayAmount = 8000;
              await poolAccountingEnv.moveInTime(oneDayToMaturity);
              await poolAccountingEnv.repayMP(
                nextPoolID,
                repayAmount.toString()
              );

              mpUserBorrowedAmount =
                await poolAccountingHarness.mpUserBorrowedAmount(
                  nextPoolID,
                  laura.address
                );
              returnValues = await poolAccountingHarness.returnValues();
              mp = await poolAccountingHarness.maturityPools(nextPoolID);
            });

            it("THEN borrowed field is updated correctly", async () => {
              // debtCovered=8000*15750/15750=8000
              // principal of 8000 => 7619 (following ratio principal-fee of 15000 and 750)
              // borrowed original (15000) - 7619 = ~7380
              expect(mp.borrowed).to.be.gt(parseUnits("7380"));
              expect(mp.borrowed).to.be.lt(parseUnits("7381"));
            });

            it("THEN supplies are correctly updated", async () => {
              expect(mp.supplied).to.eq(
                parseUnits(depositAmount.toString()) // 10k
              );
              expect(mp.suppliedSP).to.eq(parseUnits("0"));
            });
            it("THEN the debtCovered was equal to full repayAmount (8000)", async () => {
              expect(returnValues.debtCovered).to.eq(parseUnits("8000"));
            });
            it("THEN the mpUserBorrowedAmount is correctly updated (principal + fees = 7750)", async () => {
              expect(mpUserBorrowedAmount[0]).to.be.gt(parseUnits("7380"));
              expect(mpUserBorrowedAmount[0]).to.be.lt(parseUnits("7381"));
              expect(mpUserBorrowedAmount[1]).to.be.gt(parseUnits("369"));
              expect(mpUserBorrowedAmount[1]).to.be.lt(parseUnits("370"));
            });
            it("THEN earningsSP returned 125", async () => {
              expect(returnValues.earningsSP).to.eq(parseUnits("125")); // earningsUnassigned were 250, then 1 day passed so earningsSP accrued half
            });
            it("THEN the earningsTreasury returned is 0", async () => {
              expect(returnValues.earningsTreasury).to.eq(0);
            });
            it("THEN the actualRepayAmount returned is 8000 - 125", async () => {
              // Takes all the unassignedEarnings
              // first 500 were taken by the treasury
              // then 125 was accrued and earned by the SP
              // then the repay takes the rest as a discount
              expect(returnValues.actualRepayAmount).to.eq(
                parseUnits((repayAmount - 125).toString())
              );
            });
          });

          describe("AND GIVEN a repayMP at maturity(-1 DAY) with an amount of 15750 but asking a 126 discount (total EARLY repayment) ", () => {
            const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY * 1;
            let tx: any;
            beforeEach(async () => {
              await poolAccountingEnv.moveInTime(oneDayToMaturity);
              repayAmount = 15750;
              tx = poolAccountingEnv.repayMP(
                nextPoolID,
                repayAmount.toString(),
                (repayAmount - 126).toString()
              );
            });

            it("THEN the tx is reverted with TOO_MUCH_SLIPPAGE", async () => {
              await expect(tx).to.be.revertedWith("TooMuchSlippage()");
            });
          });

          describe("AND GIVEN a repayMP at maturity(+1 DAY) with an amount of 15750*1.1=17325 (total late repayment supported by SP) ", () => {
            // (to check earnings distribution) => we have the same test down below, but the differences here
            // are the pre-conditions: in this case, the borrow was supported by the SP and MP, while the one at the bottom
            // was supported by the MP
            let mp: any;
            beforeEach(async () => {
              await poolAccountingHarness.setPenaltyRate(
                parseUnits("0.1").div(exaTime.ONE_DAY)
              );
              await poolAccountingEnv.moveInTime(nextPoolID + exaTime.ONE_DAY);
              repayAmount = 17325;
              await poolAccountingEnv.repayMP(
                nextPoolID,
                repayAmount.toString()
              );

              mpUserBorrowedAmount =
                await poolAccountingHarness.mpUserBorrowedAmount(
                  nextPoolID,
                  laura.address
                );
              returnValues = await poolAccountingHarness.returnValues();
              mp = await poolAccountingHarness.maturityPools(nextPoolID);
            });

            it("THEN borrowed field is updated correctly and is 0", async () => {
              // debtCovered=17325*15750/17325=15750
              // principal of 15750 => 15000 (following ratio principal-fee of 15000 and 750)
              // borrowed original (15000) - 15000 = 0
              expect(mp.borrowed).to.be.eq(0);
            });

            it("THEN supplies are correctly updated", async () => {
              expect(mp.supplied).to.eq(
                parseUnits(depositAmount.toString()) // 10k
              );
              expect(mp.suppliedSP).to.eq(parseUnits("0"));
            });
            it("THEN the debtCovered was equal to full repayAmount", async () => {
              // debtCovered=5775*5250/5775=5250
              expect(returnValues.debtCovered).to.eq(parseUnits("15750"));
            });
            it("THEN earningsSP receive the 10% of penalties (they were supporting this borrow)", async () => {
              // 17325 - 15750 = 1575 (10% of the debt) * 1/3 ~= 525
              // ~525 + 250 (earnings unassigned)
              expect(returnValues.earningsSP).to.gt(parseUnits("774"));
              expect(returnValues.earningsSP).to.lt(parseUnits("775"));
            });
            it("THEN the mpUserBorrowedAmount position is 0", async () => {
              expect(mpUserBorrowedAmount[0]).to.be.eq(0);
              expect(mpUserBorrowedAmount[1]).to.be.eq(0);
            });
            it("THEN the earningsTreasury returned are closed to 1050", async () => {
              // 17325 - 15750 = 1575 (10% of the debt) * 1/3 = 1050
              expect(returnValues.earningsTreasury).to.gt(parseUnits("1049"));
              expect(returnValues.earningsTreasury).to.lt(parseUnits("1050"));
            });
            it("THEN the actualRepayAmount returned is almost 17325", async () => {
              expect(returnValues.actualRepayAmount).to.lt(
                parseUnits(repayAmount.toString())
              );
              expect(returnValues.actualRepayAmount).to.gt(
                parseUnits((repayAmount - 0.1).toString())
              );
            });

            afterEach(async () => {
              await poolAccountingHarness.setPenaltyRate(0);
            });
          });

          describe("AND GIVEN another depositMP with an amount of 5000 (half of 250 unassigned earnings earned) (1 day to)", () => {
            const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY;
            beforeEach(async () => {
              depositAmount = 5000;

              await poolAccountingEnv.moveInTime(oneDayToMaturity);
              await poolAccountingEnv.depositMP(
                nextPoolID,
                depositAmount.toString()
              );

              returnValues = await poolAccountingHarness.returnValues();
              mp = await poolAccountingHarness.maturityPools(nextPoolID);
              maturityPoolState.earningsSP = returnValues.earningsSP;
              maturityPoolState.earningsMP =
                returnValues.currentTotalDeposit.sub(
                  parseUnits(depositAmount.toString())
                );
              maturityPoolState.earningsUnassigned = parseUnits("0");
              mpUserSuppliedAmount =
                await poolAccountingHarness.mpUserSuppliedAmount(
                  nextPoolID,
                  laura.address
                );
            });
            it("THEN borrowed is 3x borrowAmount", async () => {
              expect(mp.borrowed).to.eq(
                parseUnits((borrowAmount * 3).toString()) // 3 borrows of 5k were made
              );
            });
            it("THEN supplied is 15000", async () => {
              expect(mp.supplied).to.eq(
                parseUnits((depositAmount + 10000).toString()) // 1 deposits of 5k + 1 deposit of 10k
              );
            });
            it("THEN suppliedSP is 0", async () => {
              expect(mp.suppliedSP).to.eq(0);
            });
            it("THEN earningsUnassigned are 0", async () => {
              expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
            });
            it("THEN lastAccrue is 1 day to maturity", async () => {
              expect(mp.lastAccrue).to.eq(oneDayToMaturity);
            });
            it("THEN the mpUserSuppliedAmount is correctly updated", async () => {
              expect(mpUserSuppliedAmount[0]).to.be.eq(
                parseUnits((depositAmount + 10000).toString())
              );
              expect(mpUserSuppliedAmount[1]).to.be.eq(
                parseUnits((250 / 2).toString())
              );
            });
            it("THEN the earningsSP returned are 125", async () => {
              expect(returnValues.earningsSP).to.eq(
                parseUnits((250 / 2).toString()) // 250 (previous unassigned) / 2 days
              );
            });
            it("THEN the earningsTreasury returned are 0", async () => {
              expect(returnValues.earningsTreasury).to.eq(parseUnits("0"));
            });
            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValues.currentTotalDeposit).to.eq(
                parseUnits((depositAmount + 250 / 2).toString())
              );
            });
            it("THEN the borrow fees are equal to all earnings distributed", async () => {
              expect(maturityPoolState.borrowFees).to.eq(
                poolAccountingEnv.getAllEarnings(maturityPoolState)
              );
            });
          });

          describe("AND GIVEN another depositMP with an amount of 5000 and with a spFeeRate of 10% (125 - (125 * 0.1) fees earned)", () => {
            const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY;
            beforeEach(async () => {
              depositAmount = 5000;

              await poolAccountingEnv
                .getRealInterestRateModel()
                .setSPFeeRate(parseUnits("0.1")); // 10% fees charged from the mp depositor yield to the sp earnings
              await poolAccountingEnv.moveInTime(oneDayToMaturity);
              await poolAccountingEnv.depositMP(
                nextPoolID,
                depositAmount.toString()
              );

              returnValues = await poolAccountingHarness.returnValues();
              mp = await poolAccountingHarness.maturityPools(nextPoolID);
              maturityPoolState.earningsSP = returnValues.earningsSP;
              maturityPoolState.earningsMP =
                returnValues.currentTotalDeposit.sub(
                  parseUnits(depositAmount.toString())
                );
              maturityPoolState.earningsUnassigned = parseUnits("0");
            });

            it("THEN borrowed is 3x borrowAmount", async () => {
              expect(mp.borrowed).to.eq(
                parseUnits((borrowAmount * 3).toString()) // 3 borrows of 5k were made
              );
            });
            it("THEN supplied is 15000", async () => {
              expect(mp.supplied).to.eq(
                parseUnits((depositAmount + 10000).toString()) // 1 deposits of 5k + 1 deposit of 10k
              );
            });
            it("THEN suppliedSP is 0", async () => {
              expect(mp.suppliedSP).to.eq(0);
            });
            it("THEN earningsUnassigned are 0", async () => {
              expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
            });
            it("THEN lastAccrue is 1 day to maturity", async () => {
              expect(mp.lastAccrue).to.eq(oneDayToMaturity);
            });
            it("THEN the earningsTreasury returned are 0", async () => {
              expect(returnValues.earningsTreasury).to.eq(parseUnits("0"));
            });
            it("THEN the earningsSP returned are 125 + 12.5", async () => {
              expect(returnValues.earningsSP).to.eq(
                parseUnits((250 / 2 + 12.5).toString()) // 250 (previous unassigned) / 2 days
              );
            });
            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValues.currentTotalDeposit).to.eq(
                parseUnits((depositAmount + 250 / 2 - 12.5).toString())
              );
            });
            it("THEN the borrow fees are equal to all earnings distributed", async () => {
              expect(maturityPoolState.borrowFees).to.eq(
                poolAccountingEnv.getAllEarnings(maturityPoolState)
              );
            });
          });

          describe("AND GIVEN another depositMP with an exorbitant amount of 100M (all fees earned - same as depositing only 5k)", () => {
            const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY;

            beforeEach(async () => {
              depositAmount = 100000000;

              await poolAccountingEnv.moveInTime(oneDayToMaturity);
              await poolAccountingEnv.depositMP(
                nextPoolID,
                depositAmount.toString()
              );

              returnValues = await poolAccountingHarness.returnValues();
              mp = await poolAccountingHarness.maturityPools(nextPoolID);
            });

            it("THEN borrowed is 3x borrowAmount", async () => {
              expect(mp.borrowed).to.eq(
                parseUnits((borrowAmount * 3).toString()) // 3 borrows of 5k where made
              );
            });
            it("THEN supplied is depositAmount + 10000 (10k are previous deposited amount)", async () => {
              expect(mp.supplied).to.eq(
                parseUnits((depositAmount + 10000).toString()) // 10000 = previous deposited amount
              );
            });
            it("THEN suppliedSP is 0", async () => {
              expect(mp.suppliedSP).to.eq(0);
            });
            it("THEN earningsUnassigned are 0", async () => {
              expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
            });
            it("THEN lastAccrue is 1 day before maturity", async () => {
              expect(mp.lastAccrue).to.eq(oneDayToMaturity);
            });
            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValues.currentTotalDeposit).to.eq(
                parseUnits((depositAmount + 125).toString())
              );
            });

            describe("AND GIVEN an EARLY repayMP with an amount of 5250 (12 hours to maturity)", () => {
              const twelveHoursToMaturity =
                nextPoolID - exaTime.ONE_DAY + exaTime.ONE_HOUR * 12;

              beforeEach(async () => {
                repayAmount = 5250;

                await poolAccountingEnv.moveInTime(twelveHoursToMaturity);
                await poolAccountingEnv.repayMP(
                  nextPoolID,
                  repayAmount.toString()
                );

                returnValues = await poolAccountingHarness.returnValues();
                mp = await poolAccountingHarness.maturityPools(nextPoolID);
              });

              it("THEN borrowed is (borrowAmount(principal) * 3 - repayAmount(principal)) = 10K", async () => {
                expect(mp.borrowed).to.eq(parseUnits("10000"));
              });
              it("THEN supplied is 100M + 10k", async () => {
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()) // 100M + 10k deposit
                );
              });
              it("THEN suppliedSP is 0", async () => {
                expect(mp.suppliedSP).to.eq(0);
              });
              it("THEN earningsUnassigned are still 0", async () => {
                expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                expect(returnValues.earningsSP).to.eq(parseUnits("0"));
              });
              it("THEN the earningsTreasury returned are 0", async () => {
                expect(returnValues.earningsTreasury).to.eq(parseUnits("0"));
              });
              it("THEN lastAccrue is 12 hours before maturity", async () => {
                expect(mp.lastAccrue).to.eq(twelveHoursToMaturity);
              });
              it("THEN the debtCovered was the full repayAmount", async () => {
                expect(returnValues.debtCovered).to.eq(
                  parseUnits(repayAmount.toString())
                );
              });
            });

            describe("AND GIVEN a total EARLY repayMP with an amount of 15750 (all debt)", () => {
              const twelveHoursToMaturity =
                nextPoolID - exaTime.ONE_DAY + exaTime.ONE_HOUR * 12;

              beforeEach(async () => {
                repayAmount = 15750;

                await poolAccountingEnv.moveInTime(twelveHoursToMaturity);
                await poolAccountingEnv.repayMP(
                  nextPoolID,
                  repayAmount.toString()
                );

                mp = await poolAccountingHarness.maturityPools(nextPoolID);
                returnValues = await poolAccountingHarness.returnValues();
              });
              it("THEN earningsUnassigned are still 0", async () => {
                expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
              });
              it("THEN the debtCovered was the full amount repaid", async () => {
                expect(returnValues.debtCovered).to.eq(
                  parseUnits(repayAmount.toString())
                );
              });
              it("THEN the earningsSP returned are 0", async () => {
                expect(returnValues.earningsSP).to.eq(parseUnits("0"));
              });
            });

            describe("AND GIVEN a total repayMP at maturity with an amount of 15750 (all debt)", () => {
              beforeEach(async () => {
                repayAmount = 15750;

                await poolAccountingEnv.moveInTime(nextPoolID);
                await poolAccountingEnv.repayMP(
                  nextPoolID,
                  repayAmount.toString()
                );

                mp = await poolAccountingHarness.maturityPools(nextPoolID);
                returnValues = await poolAccountingHarness.returnValues();
              });
              it("THEN the maturity pool state is correctly updated", async () => {
                expect(mp.borrowed).to.eq(parseUnits("0"));
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()) // 1M + 10k deposit
                );
                expect(mp.suppliedSP).to.eq(parseUnits("0"));
              });
              it("THEN the debtCovered was equal to full repayAmount", async () => {
                expect(returnValues.debtCovered).to.eq(
                  parseUnits(repayAmount.toString())
                );
              });
              it("THEN earningsUnassigned are still 0", async () => {
                expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                expect(returnValues.earningsSP).to.eq(parseUnits("0"));
              });
              describe("AND GIVEN a partial withdrawMP of 50M", () => {
                beforeEach(async () => {
                  withdrawAmount = 50000000;

                  await poolAccountingEnv.withdrawMP(
                    nextPoolID,
                    withdrawAmount.toString()
                  );

                  mp = await poolAccountingHarness.maturityPools(nextPoolID);
                  returnValues = await poolAccountingHarness.returnValues();
                  mpUserSuppliedAmount =
                    await poolAccountingHarness.mpUserSuppliedAmount(
                      nextPoolID,
                      laura.address
                    );
                });
                it("THEN the maturity pool state is correctly updated", async () => {
                  expect(mp.borrowed).to.eq(parseUnits("0"));
                  expect(mp.supplied).to.be.eq(mpUserSuppliedAmount[0]);
                  expect(mp.suppliedSP).to.eq(parseUnits("0"));
                });
                it("THEN earningsUnassigned are still 0", async () => {
                  expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
                });
                it("THEN the earningsSP returned are 0", async () => {
                  expect(returnValues.earningsSP).to.eq(parseUnits("0"));
                });
                it("THEN the mpUserSuppliedAmount is correctly updated", async () => {
                  // all supplied + earned of laura is 100010125
                  // if we withdraw 50M, then her position is scaled
                  const totalFeeEarned = mpUserSuppliedAmount[1].add(
                    mpUserSuppliedAmount[0].sub(parseUnits("50010000"))
                  );

                  expect(mpUserSuppliedAmount[0]).to.be.lt(
                    parseUnits("50010062.5")
                  );
                  expect(mpUserSuppliedAmount[0]).to.be.gt(
                    parseUnits("50010062.49")
                  );
                  expect(mpUserSuppliedAmount[1]).to.be.lt(parseUnits("62.51"));
                  expect(mpUserSuppliedAmount[1]).to.be.gt(parseUnits("62.5"));
                  expect(totalFeeEarned).to.eq(parseUnits("125"));
                });
                it("THEN the redeemAmountDiscounted returned is equal to the amount withdrawn", async () => {
                  expect(returnValues.redeemAmountDiscounted).to.eq(
                    parseUnits(withdrawAmount.toString())
                  );
                });
                it("THEN the withdrawAmount + remaining fees + supplied that still remains in the pool equals initial total deposit", async () => {
                  const mpUserSuppliedAmount =
                    await poolAccountingHarness.mpUserSuppliedAmount(
                      nextPoolID,
                      laura.address
                    );

                  expect(
                    returnValues.redeemAmountDiscounted
                      .add(mp.supplied)
                      .add(mpUserSuppliedAmount[1])
                  ).to.eq(parseUnits("100010125"));
                });
                it("THEN the earningsTreasury returned are 0", async () => {
                  expect(returnValues.earningsTreasury).to.eq(parseUnits("0"));
                });
              });
              describe("AND GIVEN a partial withdrawMP of half amount deposited + half earned fees", () => {
                beforeEach(async () => {
                  withdrawAmount = 50005062.5; // 5k + 50M + 62.5 earned fees

                  await poolAccountingEnv.withdrawMP(
                    nextPoolID,
                    withdrawAmount.toString()
                  );

                  mp = await poolAccountingHarness.maturityPools(nextPoolID);
                  returnValues = await poolAccountingHarness.returnValues();
                });
                it("THEN the maturity pool state is correctly updated", async () => {
                  expect(mp.borrowed).to.eq(parseUnits("0"));
                  expect(mp.supplied).to.eq(parseUnits("50005000"));
                  expect(mp.suppliedSP).to.eq(parseUnits("0"));
                });
                it("THEN earningsUnassigned are still 0", async () => {
                  expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
                });
                it("THEN the earningsSP returned are 0", async () => {
                  expect(returnValues.earningsSP).to.eq(parseUnits("0"));
                });
                it("THEN the redeemAmountDiscounted returned is equal to the amount withdrawn", async () => {
                  expect(returnValues.redeemAmountDiscounted).to.eq(
                    parseUnits(withdrawAmount.toString())
                  );
                });
                it("THEN the earningsTreasury returned are 0", async () => {
                  expect(returnValues.earningsTreasury).to.eq(parseUnits("0"));
                });
                describe("AND GIVEN a borrow of 100k that leaves the pool without enough liquidity", () => {
                  beforeEach(async () => {
                    await poolAccountingEnv.borrowMP(nextPoolID, "100000");
                  });
                  describe("AND GIVEN the other half amount deposited + half earned fees is withdrawn", () => {
                    beforeEach(async () => {
                      withdrawAmount = 50005062.5; // 5k + 50M + 62.5 earned fees

                      await poolAccountingEnv.withdrawMP(
                        nextPoolID,
                        withdrawAmount.toString()
                      );

                      mp = await poolAccountingHarness.maturityPools(
                        nextPoolID
                      );
                      returnValues = await poolAccountingHarness.returnValues();
                    });
                    it("THEN the maturity pool state is correctly updated", async () => {
                      expect(mp.borrowed).to.eq(parseUnits("100000")); // 100k borrowed
                      expect(mp.supplied).to.eq(parseUnits("0"));
                      expect(mp.suppliedSP).to.eq(parseUnits("100000")); // 100k borrowed
                    });
                    it("THEN the smartPoolBorrowed is equal to 100k", async () => {
                      expect(
                        await poolAccountingHarness.smartPoolBorrowed()
                      ).to.eq(parseUnits("100000"));
                    });
                    it("THEN earningsUnassigned are still 0", async () => {
                      expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
                    });
                    it("THEN the earningsSP returned are 0", async () => {
                      expect(returnValues.earningsSP).to.eq(parseUnits("0"));
                    });
                    it("THEN the redeemAmountDiscounted returned is equal to the amount withdrawn", async () => {
                      expect(returnValues.redeemAmountDiscounted).to.eq(
                        parseUnits(withdrawAmount.toString())
                      );
                    });
                    it("THEN the earningsTreasury returned are 0", async () => {
                      expect(returnValues.earningsTreasury).to.eq(
                        parseUnits("0")
                      );
                    });
                  });
                });
              });
              describe("AND GIVEN a total withdrawMP of the total amount deposited + earned fees", () => {
                beforeEach(async () => {
                  withdrawAmount = 100010125; // 10k + 100M + 125 earned fees

                  await poolAccountingEnv.withdrawMP(
                    nextPoolID,
                    withdrawAmount.toString()
                  );

                  mp = await poolAccountingHarness.maturityPools(nextPoolID);
                  returnValues = await poolAccountingHarness.returnValues();
                });
                it("THEN the maturity pool state is correctly updated", async () => {
                  expect(mp.borrowed).to.eq(parseUnits("0"));
                  expect(mp.supplied).to.eq(parseUnits("0"));
                  expect(mp.suppliedSP).to.eq(parseUnits("0"));
                });
                it("THEN earningsUnassigned are still 0", async () => {
                  expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
                });
                it("THEN the earningsSP returned are 0", async () => {
                  expect(returnValues.earningsSP).to.eq(parseUnits("0"));
                });
                it("THEN the redeemAmountDiscounted returned is equal to all amount withdrawn", async () => {
                  expect(returnValues.redeemAmountDiscounted).to.eq(
                    parseUnits(withdrawAmount.toString())
                  );
                });
                it("THEN the earningsTreasury returned are 0", async () => {
                  expect(returnValues.earningsTreasury).to.eq(parseUnits("0"));
                });
              });
            });

            describe("AND GIVEN a partial repayMP at maturity(+1 DAY) with an amount of 8000 (partial late repayment)", () => {
              let mp: any;
              beforeEach(async () => {
                await poolAccountingHarness.setPenaltyRate(
                  parseUnits("0.1").div(exaTime.ONE_DAY)
                );

                await poolAccountingEnv.moveInTime(
                  nextPoolID + exaTime.ONE_DAY
                );
                repayAmount = 8000;
                await poolAccountingEnv.repayMP(
                  nextPoolID,
                  repayAmount.toString()
                );
                returnValues = await poolAccountingHarness.returnValues();
                mp = await poolAccountingHarness.maturityPools(nextPoolID);
              });

              it("THEN borrowed field is updated correctly (~8073)", async () => {
                // debtCovered=8000*15750/17325=~7272
                // principal of ~7272 => ~6926 (following ratio principal-fee of 15000 and 750)
                // borrowed original (15000) - ~6296 = ~8073
                //
                expect(mp.borrowed).to.be.gt(parseUnits("8073.59"));
                expect(mp.borrowed).to.be.lt(parseUnits("8073.60"));
              });

              it("THEN supplies are correctly updated", async () => {
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()) // 1M + 10k deposit
                );
                expect(mp.suppliedSP).to.eq(parseUnits("0"));
              });
              it("THEN the debtCovered was equal to full repayAmount", async () => {
                // debtCovered=8000*15750/17325=~7272
                expect(returnValues.debtCovered).to.gt(parseUnits("7272.72"));
                expect(returnValues.debtCovered).to.lt(parseUnits("7272.73"));
              });
              it("THEN earningsTreasury receive the 10% of penalties (they were supporting this borrow)", async () => {
                // debtCovered=8000*15750/17325=~7272
                // debtCovered+(~727)=8000 that the user repaid
                expect(returnValues.earningsTreasury).to.gt(
                  parseUnits("727.272")
                );
                expect(returnValues.earningsTreasury).to.lt(
                  parseUnits("727.273")
                );
              });
              it("THEN the earningsSP returned are 0", async () => {
                expect(returnValues.earningsSP).to.eq(parseUnits("0"));
              });

              afterEach(async () => {
                await poolAccountingHarness.setPenaltyRate(0);
              });
            });

            describe("AND GIVEN a repayMP at maturity(+1 DAY) with an amount of 15750*1.1=17325 (total late repayment)", () => {
              let mp: any;
              beforeEach(async () => {
                await poolAccountingHarness.setPenaltyRate(
                  parseUnits("0.1").div(exaTime.ONE_DAY)
                );

                await poolAccountingEnv.moveInTime(
                  nextPoolID + exaTime.ONE_DAY
                );
                repayAmount = 17325;
                await poolAccountingEnv.repayMP(
                  nextPoolID,
                  repayAmount.toString()
                );
                returnValues = await poolAccountingHarness.returnValues();
                mp = await poolAccountingHarness.maturityPools(nextPoolID);
              });

              it("THEN borrowed field is updated correctly and is 0", async () => {
                // debtCovered=17325*15750/17325=15750
                // principal of 15750 => 15000 (following ratio principal-fee of 15000 and 750)
                // borrowed original (15000) - 15000 = 0
                expect(mp.borrowed).to.be.eq(0);
              });

              it("THEN supplies are correctly updated", async () => {
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()) // 1M + 10k deposit
                );
                expect(mp.suppliedSP).to.eq(parseUnits("0"));
              });
              it("THEN the debtCovered was equal to full repayAmount", async () => {
                // debtCovered=17325*15750/17325=15750
                expect(returnValues.debtCovered).to.eq(parseUnits("15750"));
              });
              it("THEN earningsTreasury receive the 10% of penalties (they were supporting this borrow)", async () => {
                // 17325 - 15750 = 1575 (10% of the debt)
                expect(returnValues.earningsTreasury).to.gt(parseUnits("1574"));
                expect(returnValues.earningsTreasury).to.lt(parseUnits("1575"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                expect(returnValues.earningsSP).to.eq(parseUnits("0"));
              });
              it("THEN the actualRepayAmount returned is almost 17325", async () => {
                expect(returnValues.actualRepayAmount).to.lt(
                  parseUnits(repayAmount.toString())
                );
                expect(returnValues.actualRepayAmount).to.gt(
                  parseUnits((repayAmount - 0.1).toString())
                );
              });
            });

            describe("AND GIVEN a repayMP at maturity(+1 DAY) with an amount of 2000 on a debt 15750*0.1=17325 (way more money late repayment)", () => {
              let mp: any;
              beforeEach(async () => {
                await poolAccountingHarness.setPenaltyRate(
                  parseUnits("0.1").div(exaTime.ONE_DAY)
                );

                await poolAccountingEnv.moveInTime(
                  nextPoolID + exaTime.ONE_DAY
                );
                repayAmount = 20000;
                await poolAccountingEnv.repayMP(
                  nextPoolID,
                  repayAmount.toString()
                );
                returnValues = await poolAccountingHarness.returnValues();
                mp = await poolAccountingHarness.maturityPools(nextPoolID);
              });

              it("THEN borrowed field is updated correctly and is 0", async () => {
                // debtCovered=17325*15750/17325=15750
                // principal of 15750 => 15000 (following ratio principal-fee of 15000 and 750)
                // borrowed original (15000) - 15000 = 0
                expect(mp.borrowed).to.be.eq(0);
              });

              it("THEN supplies are correctly updated", async () => {
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()) // 1M + 10k deposit
                );
                expect(mp.suppliedSP).to.eq(parseUnits("0"));
              });
              it("THEN the debtCovered was equal to full repayAmount", async () => {
                // debtCovered=17325*15750/17325=15750
                expect(returnValues.debtCovered).to.eq(parseUnits("15750"));
              });
              it("THEN earningsTreasury receive the 10% of penalties (they were supporting this borrow)", async () => {
                // 17325 - 15750 = 1575 (10% of the debt)
                expect(returnValues.earningsTreasury).to.gt(parseUnits("1574"));
                expect(returnValues.earningsTreasury).to.lt(parseUnits("1575"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                expect(returnValues.earningsSP).to.eq(parseUnits("0"));
              });
              it("THEN the actualRepayAmount returned is ~= 17325 (paid 20000 on a 17325 debt)", async () => {
                expect(returnValues.actualRepayAmount).to.be.gt(
                  parseUnits("17324.9")
                );
                expect(returnValues.actualRepayAmount).to.be.lt(
                  parseUnits("17325")
                );
              });
            });
          });
        });
      });
    });
  });

  describe("GIVEN a protocolSpreadFee of 10%", () => {
    let borrowAmount: number;
    let borrowFees: number;
    let returnValues: any;
    let mpUserBorrowedAmount: any;
    let mp: any;

    beforeEach(async () => {
      await poolAccountingHarness.setProtocolSpreadFee(parseUnits("0.1"));
      await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
      poolAccountingEnv.switchWallet(laura);
    });
    describe("AND GIVEN borrowMP with an amount of 5000 (250 charged in fees, where 25 goes to treasury)", () => {
      beforeEach(async () => {
        borrowAmount = 5000;
        borrowFees = 250;

        await poolAccountingEnv.borrowMP(
          nextPoolID,
          borrowAmount.toString(),
          (borrowAmount + borrowFees).toString()
        );

        mpUserBorrowedAmount = await poolAccountingHarness.mpUserBorrowedAmount(
          nextPoolID,
          laura.address
        );
        returnValues = await poolAccountingHarness.returnValues();
        mp = await poolAccountingHarness.maturityPools(nextPoolID);
      });
      it("THEN earningsUnassigned are 225", async () => {
        expect(mp.earningsUnassigned).to.eq(parseUnits("225"));
      });
      it("THEN the mpUserBorrowedAmount is correctly updated", async () => {
        expect(mpUserBorrowedAmount[0]).to.equal(
          parseUnits(borrowAmount.toString())
        );
        expect(mpUserBorrowedAmount[1]).to.equal(
          parseUnits(borrowFees.toString())
        );
      });
      it("THEN the earningsTreasury returned are 25", async () => {
        expect(returnValues.earningsTreasury).to.equal(parseUnits("25"));
      });
      it("THEN the earningsSP returned are 0", async () => {
        expect(returnValues.earningsSP).to.equal(parseUnits("0"));
      });
      it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
        expect(returnValues.totalOwedNewBorrow).to.equal(
          parseUnits((borrowAmount + borrowFees).toString())
        );
      });
    });
    describe("GIVEN a depositMP with an amount of 5000", () => {
      beforeEach(async () => {
        await poolAccountingEnv.depositMP(nextPoolID, "5000");
      });
      describe("AND GIVEN a borrowMP with an amount of 5000", () => {
        beforeEach(async () => {
          borrowAmount = 5000;
          borrowFees = 250;

          await poolAccountingEnv.borrowMP(
            nextPoolID,
            borrowAmount.toString(),
            (borrowAmount + borrowFees).toString()
          );

          mpUserBorrowedAmount =
            await poolAccountingHarness.mpUserBorrowedAmount(
              nextPoolID,
              laura.address
            );
          returnValues = await poolAccountingHarness.returnValues();
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
        });
        it("THEN earningsUnassigned are 0", async () => {
          expect(mp.earningsUnassigned).to.equal(0);
        });
        it("THEN the mpUserBorrowedAmount is correctly updated", async () => {
          expect(mpUserBorrowedAmount[0]).to.equal(
            parseUnits(borrowAmount.toString())
          );
          expect(mpUserBorrowedAmount[1]).to.equal(
            parseUnits(borrowFees.toString())
          );
        });
        it("THEN the earningsTreasury returned are 250", async () => {
          expect(returnValues.earningsTreasury).to.equal(parseUnits("250"));
        });
        it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
          expect(returnValues.totalOwedNewBorrow).to.equal(
            parseUnits((borrowAmount + borrowFees).toString())
          );
        });
      });
      describe("AND GIVEN a borrowMP with an amount of 10000 (500 charged in fees, 50 + 225 to treasury, 225 to unassigned)", () => {
        beforeEach(async () => {
          borrowAmount = 10000;
          borrowFees = 500;

          await poolAccountingEnv.borrowMP(
            nextPoolID,
            borrowAmount.toString(),
            (borrowAmount + borrowFees).toString()
          );

          mpUserBorrowedAmount =
            await poolAccountingHarness.mpUserBorrowedAmount(
              nextPoolID,
              laura.address
            );
          returnValues = await poolAccountingHarness.returnValues();
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
        });
        it("THEN earningsUnassigned are 225", async () => {
          expect(mp.earningsUnassigned).to.equal(parseUnits("225"));
        });
        it("THEN the mpUserBorrowedAmount is correctly updated", async () => {
          expect(mpUserBorrowedAmount[0]).to.equal(
            parseUnits(borrowAmount.toString())
          );
          expect(mpUserBorrowedAmount[1]).to.equal(
            parseUnits(borrowFees.toString())
          );
        });
        it("THEN the earningsTreasury returned are 275", async () => {
          expect(returnValues.earningsTreasury).to.equal(parseUnits("275"));
        });
        it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
          expect(returnValues.totalOwedNewBorrow).to.equal(
            parseUnits((borrowAmount + borrowFees).toString())
          );
        });
      });
    });
  });

  describe("Assignment of earnings over time", () => {
    describe("GIVEN a borrowMP of 10000 (600 fees owed by user) - 6 days to maturity", () => {
      const sixDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 6;
      let returnValues: any;
      let mp: any;

      beforeEach(async () => {
        poolAccountingEnv.switchWallet(laura);
        await mockedInterestRateModel.setBorrowRate(parseUnits("0.06"));
        await poolAccountingEnv.moveInTime(sixDaysToMaturity);
        await poolAccountingEnv.borrowMP(nextPoolID, "10000");
      });
      describe("AND GIVEN a depositMP of 1000 (50 fees earned by user) - 5 days to maturity", () => {
        const fiveDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 5;

        beforeEach(async () => {
          await poolAccountingEnv.moveInTime(fiveDaysToMaturity);
          await poolAccountingEnv.depositMP(nextPoolID, "1000");
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
          returnValues = await poolAccountingHarness.returnValues();
        });
        it("THEN earningsUnassigned should be 360", () => {
          expect(mp.earningsUnassigned).to.eq(parseUnits("450")); // 600 - 100 (earningsSP) - 50 (earnings MP depositor)
        });
        it("THEN the earningsSP returned are 100", async () => {
          expect(returnValues.earningsSP).to.eq(parseUnits("100")); // 1 day passed
        });
        it("THEN the currentTotalDeposit returned is 1050", async () => {
          expect(returnValues.currentTotalDeposit).to.eq(parseUnits("1050"));
        });
        describe("AND GIVEN a withdraw of 1050 - 4 days to maturity", () => {
          const fourDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 4;

          beforeEach(async () => {
            await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
            await poolAccountingEnv.moveInTime(fourDaysToMaturity);
            await poolAccountingEnv.withdrawMP(nextPoolID, "1050", "1000");
            mp = await poolAccountingHarness.maturityPools(nextPoolID);
            returnValues = await poolAccountingHarness.returnValues();
          });
          it("THEN earningsUnassigned should be 410", () => {
            expect(mp.earningsUnassigned).to.eq(parseUnits("410")); // 450 - 90 + 50
          });
          it("THEN the earningsSP returned are 90", async () => {
            expect(returnValues.earningsSP).to.eq(parseUnits("90")); // 450 / 5
          });
          it("THEN the earningsTreasury returned is 0", async () => {
            expect(returnValues.earningsTreasury).to.eq(parseUnits("0"));
          });
          describe("AND GIVEN another borrowMP of 10000 (601.5 fees owed by user) - 3 days to maturity", () => {
            const threeDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 3;

            beforeEach(async () => {
              await mockedInterestRateModel.setBorrowRate(
                parseUnits("0.06015")
              );
              await poolAccountingEnv.moveInTime(threeDaysToMaturity);
              await poolAccountingEnv.borrowMP(nextPoolID, "10000");
              mp = await poolAccountingHarness.maturityPools(nextPoolID);
              returnValues = await poolAccountingHarness.returnValues();
            });
            it("THEN earningsUnassigned should be 909", () => {
              expect(mp.earningsUnassigned).to.eq(parseUnits("909")); // 410 - 102.5 (410 / 4) + 601.5
            });
            it("THEN the earningsSP returned are 102.5", async () => {
              expect(returnValues.earningsSP).to.eq(parseUnits("102.5")); // (410 / 4)
            });
            it("THEN the totalOwedNewBorrow returned is 10601.5", async () => {
              expect(returnValues.totalOwedNewBorrow).to.eq(
                parseUnits("10601.5")
              );
            });
            describe("AND GIVEN a repayMP of 10600.75 (half of borrowed) - 2 days to maturity", () => {
              const twoDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 2;

              beforeEach(async () => {
                await poolAccountingEnv.moveInTime(twoDaysToMaturity);
                await poolAccountingEnv.repayMP(nextPoolID, "10600.75");
                mp = await poolAccountingHarness.maturityPools(nextPoolID);
                returnValues = await poolAccountingHarness.returnValues();
              });
              it("THEN earningsUnassigned should be 303", () => {
                expect(mp.earningsUnassigned).to.eq(parseUnits("303"));
              });
              it("THEN the earningsSP returned are 303", async () => {
                expect(returnValues.earningsSP).to.eq(parseUnits("303")); // 909 / 3
              });
              it("THEN the actualRepayAmount returned is 10600.75 - 303", async () => {
                expect(returnValues.actualRepayAmount).to.eq(
                  parseUnits("10297.75") // 10600.75 - (909 - 303) / 2
                );
              });
              it("THEN the debtCovered returned is 10600.75", async () => {
                expect(returnValues.debtCovered).to.eq(parseUnits("10600.75"));
              });
              describe("AND GIVEN a repayMP of the other half (10600.75) - 1 day to maturity", () => {
                const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY * 1;

                beforeEach(async () => {
                  await poolAccountingEnv.moveInTime(oneDayToMaturity);
                  await poolAccountingEnv.repayMP(nextPoolID, "10600.75");
                  mp = await poolAccountingHarness.maturityPools(nextPoolID);
                  returnValues = await poolAccountingHarness.returnValues();
                });
                it("THEN earningsUnassigned should be 0", () => {
                  expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
                });
                it("THEN the earningsSP returned are 151.5", async () => {
                  expect(returnValues.earningsSP).to.eq(parseUnits("151.5")); // 303 / 2
                });
                it("THEN the actualRepayAmount returned is 10600.75 - 151.5", async () => {
                  expect(returnValues.actualRepayAmount).to.eq(
                    parseUnits("10449.25")
                  );
                });
                it("THEN the debtCovered returned is 10600.75", async () => {
                  expect(returnValues.debtCovered).to.eq(
                    parseUnits("10600.75")
                  );
                });
              });
            });
          });
        });
      });
    });
  });

  describe("PoolAccounting Early Withdrawal / Early Repayment", () => {
    let returnValues: any;
    let mp: any;
    let borrowAmount: number;
    const maturityPoolState: MaturityPoolState = {
      borrowFees: parseUnits("0"),
      earningsTreasury: parseUnits("0"),
      earningsUnassigned: parseUnits("0"),
      earningsSP: parseUnits("0"),
      earningsMP: parseUnits("0"),
      earningsDiscounted: parseUnits("0"),
    };

    beforeEach(async () => {
      await provider.send("evm_setAutomine", [false]);
    });

    afterEach(async () => {
      await provider.send("evm_setAutomine", [true]);
    });

    describe("GIVEN a borrowMP of 10000 (500 fees owed by user)", () => {
      const fiveDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 5;

      beforeEach(async () => {
        borrowAmount = 10000;

        poolAccountingEnv.switchWallet(laura);
        await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await poolAccountingEnv.moveInTime(fiveDaysToMaturity);
        await poolAccountingEnv.borrowMP(nextPoolID, borrowAmount.toString());
        await provider.send("hardhat_mine", ["0x2", "0x0"]);

        mp = await poolAccountingHarness.maturityPools(nextPoolID);
        returnValues = await poolAccountingHarness.returnValues();
        maturityPoolState.borrowFees = returnValues.totalOwedNewBorrow.sub(
          parseUnits(borrowAmount.toString())
        );
      });

      it("THEN all earningsUnassigned should be 500", () => {
        expect(mp.earningsUnassigned).to.eq(parseUnits("500"));
      });

      describe("WHEN an early repayment of 5250", () => {
        beforeEach(async () => {
          await poolAccountingEnv.repayMP(nextPoolID, "5250");
          await provider.send("hardhat_mine", ["0x2", "0x0"]);
          returnValues = await poolAccountingHarness.returnValues();
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
          maturityPoolState.earningsDiscounted = parseUnits("5250").sub(
            returnValues.actualRepayAmount
          );
        });
        it("THEN borrowed is 5000", async () => {
          expect(mp.borrowed).to.eq(parseUnits("5000"));
        });
        it("THEN all earningsUnassigned should be 250", async () => {
          expect(mp.earningsUnassigned).to.eq(parseUnits("250"));
        });
        it("THEN the debtCovered returned is 5250", async () => {
          expect(returnValues.debtCovered).eq(parseUnits("5250"));
        });
        it("THEN the earningsSP returned are 0", async () => {
          expect(returnValues.earningsSP).eq(parseUnits("0")); // no seconds passed since last accrual
        });
        it("THEN the actualRepayAmount returned is 5000 (got a 250 discount)", async () => {
          expect(returnValues.actualRepayAmount).to.eq(parseUnits("5000"));
        });

        describe("AND WHEN an early repayment of 5250", () => {
          beforeEach(async () => {
            await poolAccountingEnv.repayMP(nextPoolID, "5250");
            await provider.send("hardhat_mine", ["0x2", "0x0"]);
            returnValues = await poolAccountingHarness.returnValues();
            mp = await poolAccountingHarness.maturityPools(nextPoolID);
            maturityPoolState.earningsDiscounted =
              maturityPoolState.earningsDiscounted.add(
                parseUnits("5250").sub(returnValues.actualRepayAmount)
              );
          });
          it("THEN borrowed is 0", async () => {
            expect(mp.borrowed).to.eq(0);
          });
          it("THEN suppliedSP is 0", async () => {
            expect(mp.suppliedSP).to.eq(0);
          });
          it("THEN all earningsUnassigned should be 0", async () => {
            expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
          });
          it("THEN the debtCovered returned is 5250", async () => {
            expect(returnValues.debtCovered).eq(parseUnits("5250"));
          });
          it("THEN the earningsSP returned are 0", async () => {
            expect(returnValues.earningsSP).eq(parseUnits("0")); // no seconds passed since last accrual
          });
          it("THEN the actualRepayAmount returned is 5000 (got a 250 discount)", async () => {
            expect(returnValues.actualRepayAmount).to.eq(parseUnits("5000"));
          });
          it("THEN the borrow fees are equal to all earnings distributed", async () => {
            expect(maturityPoolState.borrowFees).to.eq(
              poolAccountingEnv.getAllEarnings(maturityPoolState)
            );
          });
        });
        describe("AND WHEN an early repayment of 5250 with a spFeeRate of 10%", () => {
          beforeEach(async () => {
            await poolAccountingEnv
              .getRealInterestRateModel()
              .setSPFeeRate(parseUnits("0.1"));
            await poolAccountingEnv.repayMP(nextPoolID, "5250");
            await provider.send("hardhat_mine", ["0x2", "0x0"]);
            returnValues = await poolAccountingHarness.returnValues();
            mp = await poolAccountingHarness.maturityPools(nextPoolID);
            maturityPoolState.earningsDiscounted =
              maturityPoolState.earningsDiscounted.add(
                parseUnits("5250").sub(returnValues.actualRepayAmount)
              );
            maturityPoolState.earningsSP = returnValues.earningsSP;
          });
          it("THEN borrowed is 0", async () => {
            expect(mp.borrowed).to.eq(0);
          });
          it("THEN suppliedSP is 0", async () => {
            expect(mp.suppliedSP).to.eq(0);
          });
          it("THEN all earningsUnassigned should be 0", async () => {
            expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
          });
          it("THEN the debtCovered returned is 5250", async () => {
            expect(returnValues.debtCovered).eq(parseUnits("5250"));
          });
          it("THEN the earningsSP returned are 25 (10% spFeeRate)", async () => {
            expect(returnValues.earningsSP).eq(parseUnits("25"));
          });
          it("THEN the actualRepayAmount returned is 5025 = 5250 - 250 - 25 (10% spFeeRate)", async () => {
            expect(returnValues.actualRepayAmount).to.eq(parseUnits("5025"));
          });
          it("THEN the borrow fees are equal to all earnings distributed", async () => {
            expect(maturityPoolState.borrowFees).to.eq(
              poolAccountingEnv.getAllEarnings(maturityPoolState)
            );
          });
        });
      });
    });

    describe("GIVEN a borrowMP of 5000 (250 fees owed by user) AND a depositMP of 5000 (earns 250 in fees)", () => {
      const fiveDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 5;

      beforeEach(async () => {
        borrowAmount = 5000;

        poolAccountingEnv.switchWallet(laura);
        await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await poolAccountingEnv.moveInTime(fiveDaysToMaturity);
        await poolAccountingEnv.borrowMP(nextPoolID, borrowAmount.toString());
        await poolAccountingEnv.depositMP(nextPoolID, "5000");
        await provider.send("hardhat_mine", ["0x2", "0x0"]);

        returnValues = await poolAccountingHarness.returnValues();
        mp = await poolAccountingHarness.maturityPools(nextPoolID);
        maturityPoolState.earningsMP = returnValues.currentTotalDeposit.sub(
          parseUnits("5000")
        );
        maturityPoolState.borrowFees = returnValues.totalOwedNewBorrow.sub(
          parseUnits(borrowAmount.toString())
        );
        maturityPoolState.earningsDiscounted = parseUnits("0");
      });
      it("THEN all earningsUnassigned should be 0", async () => {
        expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
      });
      it("THEN the earningsSP returned are 0", async () => {
        expect(returnValues.earningsSP).eq(parseUnits("0"));
      });
      it("THEN the currentTotalDeposit returned is 5000 + 250 (earned fees)", async () => {
        expect(returnValues.currentTotalDeposit).eq(parseUnits("5250"));
      });

      describe("WHEN an early repayment of 5250", () => {
        beforeEach(async () => {
          await poolAccountingEnv.repayMP(nextPoolID, "5250");
          await provider.send("hardhat_mine", ["0x2", "0x0"]);
          returnValues = await poolAccountingHarness.returnValues();
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
          maturityPoolState.earningsSP = returnValues.earningsSP;
        });
        it("THEN borrowed is 0", async () => {
          expect(mp.borrowed).to.eq(parseUnits("0"));
        });
        it("THEN all earningsUnassigned should be 0", async () => {
          expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
        });
        it("THEN the earningsSP returned are 0", async () => {
          expect(returnValues.earningsSP).eq(parseUnits("0"));
        });
        it("THEN the debtCovered returned is 5250", async () => {
          expect(returnValues.debtCovered).eq(parseUnits("5250"));
        });
        it("THEN the actualRepayAmount returned is 5250 (didn't get a discount since it was gotten all before)", async () => {
          expect(returnValues.actualRepayAmount).to.eq(parseUnits("5250"));
        });
        it("THEN the borrow fees are equal to all earnings distributed", async () => {
          expect(maturityPoolState.borrowFees).to.eq(
            poolAccountingEnv.getAllEarnings(maturityPoolState)
          );
        });
      });

      describe("WHEN an early withdrawal of 5250 without enough slippage", () => {
        let tx: any;
        beforeEach(async () => {
          await provider.send("evm_setAutomine", [true]);
          tx = poolAccountingEnv.withdrawMP(nextPoolID, "5250", "5250");
        });
        it("THEN it should revert with error TOO_MUCH_SLIPPAGE", async () => {
          await expect(tx).to.be.revertedWith("TooMuchSlippage()");
        });
      });

      describe("WHEN an early withdrawal of 5250 (deposited + fees) and a borrow rate shoots to 10%", () => {
        beforeEach(async () => {
          await mockedInterestRateModel.setBorrowRate(parseUnits("0.1"));
          await poolAccountingEnv.withdrawMP(nextPoolID, "5250", "4750");
          await provider.send("hardhat_mine", ["0x2", "0x0"]);
          returnValues = await poolAccountingHarness.returnValues();
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
        });
        it("THEN borrowed is 5000", async () => {
          expect(mp.borrowed).to.eq(parseUnits("5000"));
        });
        it("THEN earningsUnassigned should be 477 (250 + money left on the table)", async () => {
          expect(mp.earningsUnassigned).to.eq(
            parseUnits("477.272727272727272728")
          );
        });
        it("THEN suppliedSP should be 5000", async () => {
          // 4772.72 is the real value that the smart pool needed to cover
          // but for simplicity it will cover the full 5000
          // the difference between 4772.72 and 5000 is the amount we added to the unassigned earnings due to the high borrow rate when withdrawing
          expect(mp.suppliedSP).to.eq(parseUnits("5000"));
        });
        it("THEN the redeemAmountDiscounted returned is 4772", async () => {
          // 5250 / 1.10 (1e18 + 1e17 feeRate) = 4772.72727272727272727272
          expect(returnValues.redeemAmountDiscounted).to.be.eq(
            parseUnits("4772.727272727272727272")
          );
        });
        it("THEN the earningsSP returned is 0", async () => {
          expect(returnValues.earningsSP).eq(parseUnits("0"));
        });
        it("THEN the earningsTreasury returned is 0", async () => {
          expect(returnValues.earningsTreasury).to.eq(parseUnits("0"));
        });
        it("THEN the mpUserSuppliedAmount is 0", async () => {
          const mpUserSuppliedAmount =
            await poolAccountingHarness.mpUserSuppliedAmount(
              nextPoolID,
              laura.address
            );

          expect(mpUserSuppliedAmount[0]).to.be.eq(parseUnits("0"));
          expect(mpUserSuppliedAmount[1]).to.be.eq(parseUnits("0"));
        });
      });

      describe("WHEN an early withdrawal of 5250 (deposited + fees)", () => {
        beforeEach(async () => {
          await poolAccountingEnv.withdrawMP(nextPoolID, "5250", "5000");
          await provider.send("hardhat_mine", ["0x2", "0x0"]);
          returnValues = await poolAccountingHarness.returnValues();
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
        });
        it("THEN borrowed is 0", async () => {
          expect(mp.borrowed).to.eq(parseUnits("5000"));
        });
        it("THEN earningsUnassigned should be 250 again", async () => {
          expect(mp.earningsUnassigned).to.eq(parseUnits("250"));
        });
        it("THEN the redeemAmountDiscounted returned is 5000", async () => {
          // 5250 / 1.05 (1e18 + 5e16 feeRate) = 5000
          expect(returnValues.redeemAmountDiscounted).to.be.eq(
            parseUnits("5000")
          );
        });
        it("THEN the earningsSP returned is 0", async () => {
          expect(returnValues.earningsSP).eq(parseUnits("0"));
        });
        it("THEN the earningsTreasury returned is 0", async () => {
          expect(returnValues.earningsTreasury).to.eq(parseUnits("0"));
        });
        it("THEN the mpUserSuppliedAmount is 0", async () => {
          const mpUserSuppliedAmount =
            await poolAccountingHarness.mpUserSuppliedAmount(
              nextPoolID,
              laura.address
            );

          expect(mpUserSuppliedAmount[0]).to.be.eq(parseUnits("0"));
          expect(mpUserSuppliedAmount[1]).to.be.eq(parseUnits("0"));
        });
      });
    });

    describe("User receives more money than deposited for repaying earlier", () => {
      describe("GIVEN a borrowMP of 10000 (500 fees owed by user)", () => {
        const fiveDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 5;

        beforeEach(async () => {
          poolAccountingEnv.switchWallet(laura);
          await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
          await poolAccountingEnv.moveInTime(fiveDaysToMaturity);
          await poolAccountingEnv.borrowMP(nextPoolID, "10000");
          await provider.send("hardhat_mine", ["0x2", "0x0"]);
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
        });

        it("THEN all earningsUnassigned should be 500", () => {
          expect(mp.earningsUnassigned).to.eq(parseUnits("500"));
        });

        describe("GIVEN a borrowMP of 10000 (10000 fees owed by user)", () => {
          beforeEach(async () => {
            poolAccountingEnv.switchWallet(tina);
            await mockedInterestRateModel.setBorrowRate(parseUnits("1")); // Crazy FEE
            await poolAccountingEnv.borrowMP(nextPoolID, "10000", "20000"); // ... and we accept it
            await provider.send("hardhat_mine", ["0x2", "0x0"]);
            mp = await poolAccountingHarness.maturityPools(nextPoolID);
          });

          it("THEN all earningsUnassigned should be 10500", async () => {
            expect(mp.earningsUnassigned).to.eq(parseUnits("10500"));
          });

          describe("WHEN an early repayment of 10500", () => {
            beforeEach(async () => {
              poolAccountingEnv.switchWallet(laura);
              await poolAccountingEnv.repayMP(nextPoolID, "10500");
              await provider.send("hardhat_mine", ["0x2", "0x0"]);
              returnValues = await poolAccountingHarness.returnValues();
              mp = await poolAccountingHarness.maturityPools(nextPoolID);
            });
            it("THEN borrowed is 10000", async () => {
              expect(mp.borrowed).to.eq(parseUnits("10000"));
            });
            it("THEN all earningsUnassigned should be 5250", async () => {
              expect(mp.earningsUnassigned).to.eq(parseUnits("5250"));
            });
            it("THEN the debtCovered returned is 10500", async () => {
              expect(returnValues.debtCovered).eq(parseUnits("10500"));
            });
            it("THEN the earningsSP returned are 0", async () => {
              expect(returnValues.earningsSP).eq(parseUnits("0"));
            });
            it("THEN the earningsTreasury returned are 0", async () => {
              expect(returnValues.earningsTreasury).eq(parseUnits("0"));
            });
            it("THEN the actualRepayAmount returned is 5250 (got a 5250 BIG discount)", async () => {
              expect(returnValues.actualRepayAmount).to.eq(parseUnits("5250"));
            });
          });
        });
      });
    });
  });

  afterEach(async () => {
    await provider.send("evm_revert", [snapshot]);
    await provider.send("hardhat_mine", ["0x2", "0x0"]);
  });
});
