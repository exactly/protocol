import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  ProtocolError,
  errorGeneric,
  ExaTime,
  MaturityPoolState,
} from "./exactlyUtils";
import { PoolAccountingEnv } from "./poolAccountingEnv";

describe("PoolAccounting", () => {
  let laura: SignerWithAddress;
  let poolAccountingEnv: PoolAccountingEnv;
  let poolAccountingHarness: Contract;
  let mockedInterestRateModel: Contract;
  let exaTime = new ExaTime();
  let snapshot: any;
  const nextPoolID = exaTime.nextPoolID() + 7 * exaTime.ONE_DAY; // we add 7 days so we make sure we are far from the previouos timestamp blocks

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
    [, laura] = await ethers.getSigners();
    poolAccountingEnv = await PoolAccountingEnv.create();
    poolAccountingHarness = poolAccountingEnv.poolAccountingHarness;
    mockedInterestRateModel = poolAccountingEnv.mockedInterestRateModel;
  });

  describe("function calls not originating from the FixedLender contract", () => {
    it("WHEN invoking borrowMP NOT from the FixedLender, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        poolAccountingHarness.borrowMP(0, laura.address, 0, 0, 0)
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.CALLER_MUST_BE_FIXED_LENDER)
      );
    });

    it("WHEN invoking depositMP NOT from the FixedLender, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        poolAccountingHarness.depositMP(0, laura.address, 0, 0)
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.CALLER_MUST_BE_FIXED_LENDER)
      );
    });

    it("WHEN invoking repayMP NOT from the FixedLender, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        poolAccountingHarness.repayMP(0, laura.address, 0, 0)
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.CALLER_MUST_BE_FIXED_LENDER)
      );
    });

    it("WHEN invoking withdrawMP NOT from the FixedLender, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        poolAccountingHarness.withdrawMP(0, laura.address, 0, 0, 0)
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.CALLER_MUST_BE_FIXED_LENDER)
      );
    });
  });

  describe("GIVEN a depositMP with an amount of 10000 (0 fees earned)", () => {
    const sixDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 5;
    let depositAmount: any;
    let borrowAmount: any;
    let borrowFees: any;
    let returnValues: any;
    let repayAmount: any;
    let mp: any;
    let maturityPoolState: MaturityPoolState = {
      borrowFees: parseUnits("0"),
      earningsTreasury: parseUnits("0"),
      earningsUnassigned: parseUnits("0"),
      earningsSP: parseUnits("0"),
      earningsMP: parseUnits("0"),
      earningsDiscounted: parseUnits("0"),
    };

    beforeEach(async () => {
      await poolAccountingEnv.moveInTime(sixDaysToMaturity);
      depositAmount = "10000";
      poolAccountingEnv.switchWallet(laura);
      await poolAccountingEnv.depositMP(nextPoolID, depositAmount);
      returnValues = await poolAccountingHarness.returnValues();
      mp = await poolAccountingHarness.maturityPools(nextPoolID);
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

                returnValues = await poolAccountingHarness.returnValues();
              });
              it("THEN the debtCovered was the full amount repaid", async () => {
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
            });

            describe("AND GIVEN a total repayMP at maturity with an amount of 15750 (all debt)", () => {
              beforeEach(async () => {
                repayAmount = 15750;

                await poolAccountingEnv.moveInTime(nextPoolID);
                await poolAccountingEnv.repayMP(
                  nextPoolID,
                  repayAmount.toString()
                );

                returnValues = await poolAccountingHarness.returnValues();
              });
              it("THEN the maturity pool state is correctly updated", async () => {
                const mp = await poolAccountingHarness.maturityPools(
                  nextPoolID
                );

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
    let maturityPoolState: MaturityPoolState = {
      borrowFees: parseUnits("0"),
      earningsTreasury: parseUnits("0"),
      earningsUnassigned: parseUnits("0"),
      earningsSP: parseUnits("0"),
      earningsMP: parseUnits("0"),
      earningsDiscounted: parseUnits("0"),
    };

    describe("GIVEN a borrowMP of 10000 (500 fees earned)", () => {
      const fiveDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 5;

      beforeEach(async () => {
        borrowAmount = 10000;
        maturityPoolState.borrowFees = parseUnits("500");

        poolAccountingEnv.switchWallet(laura);
        await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await poolAccountingEnv.moveInTime(fiveDaysToMaturity);
        await poolAccountingEnv.borrowMP(nextPoolID, borrowAmount.toString());

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
          returnValues = await poolAccountingHarness.returnValues();
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
          maturityPoolState.earningsDiscounted = returnValues.spareAmount;
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
        it("THEN the spareAmount returned is 250 (got a discount)", async () => {
          expect(returnValues.spareAmount).to.eq(parseUnits("250"));
        });

        describe("AND WHEN an early repayment of 5250", () => {
          beforeEach(async () => {
            await poolAccountingEnv.repayMP(nextPoolID, "5250");
            returnValues = await poolAccountingHarness.returnValues();
            mp = await poolAccountingHarness.maturityPools(nextPoolID);
            maturityPoolState.earningsDiscounted =
              maturityPoolState.earningsDiscounted.add(
                returnValues.spareAmount
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
          it("THEN the spareAmount returned is 250 (got a discount)", async () => {
            expect(returnValues.spareAmount).to.eq(parseUnits("250"));
          });
          it("THEN the borrow fees are equal to all earnings distributed", async () => {
            expect(maturityPoolState.borrowFees).to.eq(
              poolAccountingEnv.getAllEarnings(maturityPoolState)
            );
          });
        });
      });
    });

    describe("GIVEN a borrowMP of 5000 (250 fees earned) AND a depositMP of 5000", () => {
      const fiveDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 5;

      beforeEach(async () => {
        borrowAmount = 5000;

        poolAccountingEnv.switchWallet(laura);
        await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await poolAccountingEnv.moveInTime(fiveDaysToMaturity);
        await poolAccountingEnv.borrowMP(nextPoolID, borrowAmount.toString());
        await poolAccountingEnv.depositMP(nextPoolID, "5000");

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
          returnValues = await poolAccountingHarness.returnValues();
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
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
        it("THEN the spareAmount returned is 0 (didn't get a discount since it was gotten all before)", async () => {
          expect(returnValues.spareAmount).to.eq(parseUnits("0"));
        });
        it("THEN the borrow fees are equal to all earnings distributed", async () => {
          expect(maturityPoolState.borrowFees).to.eq(
            poolAccountingEnv.getAllEarnings(maturityPoolState)
          );
        });
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
