import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ProtocolError, errorGeneric, ExaTime } from "./exactlyUtils";
import { PoolAccountingEnv } from "./poolAccountingEnv";

describe("PoolAccounting", () => {
  let laura: SignerWithAddress;
  let poolAccountingEnv: PoolAccountingEnv;
  let poolAccountingHarness: Contract;
  let mockedInterestRateModel: Contract;
  let fixedLender: Contract;
  let exaTime = new ExaTime();
  let snapshot: any;
  const nextPoolID = exaTime.nextPoolID() + 7 * exaTime.ONE_DAY; // we add 7 days so we make sure we are far from the previouos timestamp blocks

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
    [, laura] = await ethers.getSigners();
    poolAccountingEnv = await PoolAccountingEnv.create();
    poolAccountingHarness = poolAccountingEnv.poolAccountingHarness;
    mockedInterestRateModel = poolAccountingEnv.interestRateModel;
    fixedLender = poolAccountingEnv.fixedLender;
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
    it("THEN earningsSP are 0", async () => {
      expect(mp.earningsSP).to.eq(parseUnits("0"));
    });
    it("THEN lastAccrue is 6 days to maturity", async () => {
      expect(mp.lastAccrue).to.eq(sixDaysToMaturity);
    });
    it("THEN the currentTotalDeposit returned is equal to the amount (no fees earned)", async () => {
      expect(returnValues.currentTotalDeposit).to.eq(parseUnits(depositAmount));
    });

    describe("AND GIVEN a borrowMP with an amount of 5000 (250 charged in fees) (4 days to go)", () => {
      const fourDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 4;
      let mp: any;
      beforeEach(async () => {
        await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await poolAccountingEnv.moveInTime(fourDaysToMaturity);
        borrowAmount = 5000;
        borrowFees = 250;
        await poolAccountingEnv.borrowMP(
          nextPoolID,
          borrowAmount.toString(),
          (borrowAmount + borrowFees).toString()
        );
        returnValues = await poolAccountingHarness.returnValues();
        mp = await poolAccountingHarness.maturityPools(nextPoolID);
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
      it("THEN earningsUnassigned are 5000 x 0,05 (5%)", async () => {
        expect(mp.earningsUnassigned).to.eq(parseUnits(borrowFees.toString())); // 5000 x 0,05 (5%)
      });
      it("THEN earningsSP are 0", async () => {
        expect(mp.earningsSP).to.eq(parseUnits("0"));
      });
      it("THEN lastAccrue is 4 days to maturity", async () => {
        expect(mp.lastAccrue).to.eq(fourDaysToMaturity);
      });
      it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
        expect(returnValues.totalOwedNewBorrow).to.eq(
          parseUnits((borrowAmount + borrowFees).toString())
        );
      });

      describe("AND GIVEN another borrowMP call with an amount of 5000 (250 charged in fees) (3 days to go)", () => {
        const threeDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 3;
        let mp: any;
        beforeEach(async () => {
          await poolAccountingEnv.moveInTime(threeDaysToMaturity);
          borrowAmount = 5000;
          borrowFees = 250;
          await poolAccountingEnv.borrowMP(
            nextPoolID,
            borrowAmount.toString(),
            (borrowAmount + borrowFees).toString()
          );
          returnValues = await poolAccountingHarness.returnValues();
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
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
        it("THEN earningsUnassigned are 250 + 250 - 250 / 4", async () => {
          expect(mp.earningsUnassigned).to.eq(
            parseUnits((borrowFees + borrowFees - borrowFees / 4).toString()) // 250 + 250 - 250 / 4
          );
        });
        it("THEN earningsTreasury are 250 / 4", async () => {
          expect(mp.earningsTreasury).to.eq(
            parseUnits((borrowFees / 4).toString())
          ); // 250 / 4
        });
        it("THEN the maturity pool state is correctly updated", async () => {
          expect(mp.lastAccrue).to.eq(threeDaysToMaturity);
        });
        it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
          expect(returnValues.totalOwedNewBorrow).to.eq(
            parseUnits((borrowAmount + borrowFees).toString())
          );
        });

        describe("AND GIVEN another borrowMP call with an amount of 5000 (250 charged in fees) (2 days to go)", () => {
          const twoDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 2;
          let mp: any;
          beforeEach(async () => {
            await poolAccountingEnv.moveInTime(twoDaysToMaturity);
            borrowAmount = 5000;
            borrowFees = 250;
            await poolAccountingEnv.borrowMP(
              nextPoolID,
              borrowAmount.toString(),
              (borrowAmount + borrowFees).toString()
            );
            returnValues = await poolAccountingHarness.returnValues();
            mp = await poolAccountingHarness.maturityPools(nextPoolID);
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
          it("THEN earningsUnassigned around 437.5", async () => {
            expect(mp.earningsUnassigned).to.be.lt(
              parseUnits((borrowFees + 437.5 - 437.5 / 3 + 1).toString()) // 437.5 = previous unassigned earnings
            );
            expect(mp.earningsUnassigned).to.be.gt(
              parseUnits((borrowFees + 437.5 - 437.5 / 3 - 1).toString())
            );
          });
          it("THEN earningsSP are still around 62.5", async () => {
            expect(mp.earningsTreasury).to.be.lt(
              parseUnits((62.5 + 437.5 / 3 + 1).toString()) // 62.5 = previous earnings SP
            );
            expect(mp.earningsTreasury).to.be.gt(
              parseUnits((62.5 + 437.5 / 3 - 1).toString())
            );
          });
          it("THEN lastAccrue is 2 days to maturity", async () => {
            expect(mp.lastAccrue).to.eq(twoDaysToMaturity);
          });
          it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
            expect(returnValues.totalOwedNewBorrow).to.eq(
              parseUnits((borrowAmount + borrowFees).toString())
            );
          });

          describe("AND GIVEN another depositMP with an amount of 10000 (180 fees earned) (1 day to)", () => {
            const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY;
            let mp: any;
            beforeEach(async () => {
              await poolAccountingEnv.moveInTime(oneDayToMaturity);
              depositAmount = 10000;
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

            it("THEN supplied is 2x depositAmount", async () => {
              expect(mp.supplied).to.eq(
                parseUnits((depositAmount * 2).toString()) // 2 deposits of 10k where made
              );
            });

            it("THEN suppliedSP is 0", async () => {
              expect(mp.suppliedSP).to.eq(0);
            });

            it("THEN earningsUnassigned are 542 / 2 - earnedFees", async () => {
              const earnedFees =
                ((542 / 2) * depositAmount) / (depositAmount + borrowAmount); // 542 = previous unassigned earnings
              const earningsUnassigned = 542 / 2 - earnedFees;

              expect(mp.earningsUnassigned).to.be.lt(
                parseUnits(earningsUnassigned.toString())
              );
              expect(mp.earningsUnassigned).to.be.gt(
                parseUnits((earningsUnassigned - 1).toString())
              );
            });

            it("THEN all earnings are around 750", async () => {
              expect(
                mp.earningsMP
                  .add(mp.earningsSP)
                  .add(mp.earningsTreasury)
                  .add(mp.earningsUnassigned)
              ).to.eq(parseUnits("750"));
            });

            it("THEN lastAccrue is 1 day to maturity", async () => {
              expect(mp.lastAccrue).to.eq(oneDayToMaturity);
            });

            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValues.currentTotalDeposit).to.be.lt(
                parseUnits((depositAmount + 172).toString())
              );
              expect(returnValues.currentTotalDeposit).to.be.gt(
                parseUnits((depositAmount + 171).toString())
              );
            });
          });

          describe("AND GIVEN another depositMP with an amount of 10000 and with a mpDepositDistributionWeighter of 150% (203 fees earned)", () => {
            const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY;
            let mp: any;
            beforeEach(async () => {
              await fixedLender.setMpDepositDistributionWeighter(
                parseUnits("1.5")
              );
              await poolAccountingEnv.moveInTime(oneDayToMaturity);
              depositAmount = 10000;
              await poolAccountingHarness
                .connect(laura)
                .depositMP(
                  nextPoolID,
                  laura.address,
                  parseUnits(depositAmount.toString()),
                  parseUnits(depositAmount.toString())
                );
              returnValues = await poolAccountingHarness.returnValues();
              mp = await poolAccountingHarness.maturityPools(nextPoolID);
            });

            it("THEN borrowed is 3x borrowAmount", async () => {
              expect(mp.borrowed).to.eq(
                parseUnits((borrowAmount * 3).toString()) // 3 borrows of 5k where made
              );
            });

            it("THEN supplied is 2x depositAmount", async () => {
              expect(mp.supplied).to.eq(
                parseUnits((depositAmount * 2).toString()) // 2 deposits of 10k where made
              );
            });

            it("THEN suppliedSP is 1x borrowAmount", async () => {
              expect(mp.suppliedSP).to.eq(parseUnits(borrowAmount.toString()));
            });

            it("THEN unassignedEarnings are 542 / 2 - earnedFees", async () => {
              depositAmount = depositAmount * 1.5;
              const earnedFees =
                ((542 / 2) * depositAmount) / (depositAmount + borrowAmount); // 542 = previous unassigned earnings
              const unassignedEarnings = 542 / 2 - earnedFees;

              expect(mp.unassignedEarnings).to.be.lt(
                parseUnits(unassignedEarnings.toString())
              );
              expect(mp.unassignedEarnings).to.be.gt(
                parseUnits((unassignedEarnings - 1).toString())
              );
            });

            it("THEN earningsSP are around 480", async () => {
              expect(mp.earningsSP).to.be.lt(parseUnits("480")); // 209 + 542 / 2
              expect(mp.earningsSP).to.be.gt(parseUnits("479")); // 209 = previous earnings SP & 542 = previous unassigned earnings
            });

            it("THEN lastAccrue is 1 day to maturity", async () => {
              expect(mp.lastAccrue).to.eq(oneDayToMaturity);
            });

            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValues.currentTotalDeposit).to.be.lt(
                parseUnits((depositAmount + 204).toString()) // earned more fees due to change in weighter
              );
              expect(returnValues.currentTotalDeposit).to.be.gt(
                parseUnits((depositAmount + 203).toString())
              );
            });
          });

          describe("AND GIVEN another depositMP with an exorbitant amount of 100M (almost all fees earned)", () => {
            const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY;

            beforeEach(async () => {
              await poolAccountingEnv.moveInTime(oneDayToMaturity);
              depositAmount = 100000000;
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
              expect(mp.earningsUnassigned).to.be.eq(parseUnits("0")); // after a very big deposit compared to the suppliedSP, almost no earningsUnassigned are left
            });

            it("THEN earningsSP are around 480", async () => {
              expect(mp.earningsSP).to.be.lt(parseUnits("480")); // 209 + 542 / 2
              expect(mp.earningsSP).to.be.gt(parseUnits("479")); // 209 = previous earnings SP & 542 = previous unassigned earnings
            });

            it("THEN lastAccrue is 1 day before maturity", async () => {
              expect(mp.lastAccrue).to.eq(oneDayToMaturity);
            });

            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValues.currentTotalDeposit).to.be.lt(
                parseUnits((depositAmount + 271).toString()) // 542 / 2 (542 = previous unassigned earnings)
              );
              expect(returnValues.currentTotalDeposit).to.be.gt(
                parseUnits((depositAmount + 270).toString())
              );
            });

            describe("AND GIVEN an EARLY repayMP with an amount of 5250 (12 hours to maturity)", () => {
              const twelveHoursToMaturity =
                nextPoolID - exaTime.ONE_DAY + exaTime.ONE_HOUR * 12;

              beforeEach(async () => {
                await poolAccountingEnv.moveInTime(twelveHoursToMaturity);
                repayAmount = 5250;
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

              it("THEN earningsUnassigned are close to 0", async () => {
                expect(mp.earningsUnassigned).to.be.lt(parseUnits("0.01"));
                expect(mp.earningsUnassigned).to.be.gt(parseUnits("0"));
              });

              it("THEN the pool 'earningsMP' is partially repaid (270 - partial repay)", async () => {
                // 249 are the fees left after discount to repay fees
                const partialRepayForEarningsMP = parseUnits("249")
                  .mul(mp.earningsMP)
                  .div(
                    mp.earningsMP.add(mp.earningsSP).add(mp.earningsUnassigned)
                  );

                // 270 were the earnings before the last repayment
                expect(mp.earningsMP).to.be.gt(
                  parseUnits("270").sub(partialRepayForEarningsMP)
                );
                expect(mp.earningsMP).to.be.lt(
                  parseUnits("271").sub(partialRepayForEarningsMP)
                );
              });

              it("THEN earningsSP are around 479 minus partial repayment", async () => {
                // 249 are the fees left after discount to repay fees
                const partialRepayForEarningsSP = parseUnits("249")
                  .mul(mp.earningsSP)
                  .div(
                    mp.earningsMP.add(mp.earningsSP).add(mp.earningsUnassigned)
                  );

                expect(mp.earningsSP).to.be.lt(
                  parseUnits("479").sub(partialRepayForEarningsSP)
                ); // earnings added are inappreciable
                expect(mp.earningsSP).to.be.gt(
                  parseUnits("478").sub(partialRepayForEarningsSP)
                );
              });

              it("THEN lastAccrue is 12 hours before maturity", async () => {
                expect(mp.lastAccrue).to.eq(twelveHoursToMaturity);
              });

              it("THEN the debtCovered was the full repayAmount", async () => {
                expect(returnValues.debtCovered).to.be.eq(
                  parseUnits(repayAmount.toString())
                );
              });

              it("THEN the fee was 159", async () => {
                // approximation:
                // 249 are the fees left after discount to repay fees
                // const partialRepayForEarningsSP = parseUnits("249")
                //   .mul(mp.earningsSP)
                //   .div(
                //     mp.earningsMP.add(mp.earningsSP).add(mp.earningsUnassigned)
                //   );
                expect(returnValues.fee).to.be.gt(parseUnits("159"));
                expect(returnValues.fee).to.be.lt(parseUnits("160"));
              });

              it("THEN the earningsRepay was is 0.001 due to early repayment", async () => {
                // approximation:
                // 249 are the fees left after discount to repay fees
                // const partialRepayForEarningsSP = parseUnits("249")
                //   .mul(mp.earningsUnassigned)
                //   .div(
                //     mp.earningsMP.add(mp.earningsSP).add(mp.earningsUnassigned)
                //   );
                expect(returnValues.earningsRepay).to.be.gt(
                  parseUnits("0.0010")
                );
                expect(returnValues.earningsRepay).to.be.gt(
                  parseUnits("0.0011")
                );
              });
            });

            describe("AND GIVEN a total EARLY repayMP with an amount of 15750 (all debt)", () => {
              const twelveHoursToMaturity =
                nextPoolID - exaTime.ONE_DAY + exaTime.ONE_HOUR * 12;

              beforeEach(async () => {
                await poolAccountingEnv.moveInTime(twelveHoursToMaturity);
                repayAmount = 15750;
                await poolAccountingEnv.repayMP(
                  nextPoolID,
                  repayAmount.toString()
                );
                returnValues = await poolAccountingHarness.returnValues();
              });
              it("THEN the debtCovered was the full amount repaid", async () => {
                expect(returnValues.debtCovered).to.be.eq(
                  parseUnits(repayAmount.toString())
                );
              });
              it("THEN the fee was around 479", async () => {
                expect(returnValues.fee).to.be.lt(parseUnits("480"));
                expect(returnValues.fee).to.be.gt(parseUnits("479"));
              });
              it("THEN the earningsRepay was 0", async () => {
                expect(returnValues.earningsRepay).to.be.gt(
                  parseUnits("0.0010")
                );
                expect(returnValues.earningsRepay).to.be.gt(
                  parseUnits("0.0011")
                );
              });
            });

            describe("AND GIVEN a total repayMP at maturity with an amount of 15750 (all debt)", () => {
              beforeEach(async () => {
                await poolAccountingEnv.moveInTime(nextPoolID);
                repayAmount = 15750;
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
                expect(returnValues.debtCovered).to.be.eq(
                  parseUnits(repayAmount.toString())
                );
              });
              it("THEN the fee was around 479", async () => {
                expect(returnValues.fee).to.be.lt(parseUnits("480"));
                expect(returnValues.fee).to.be.gt(parseUnits("479"));
              });
              it("THEN the earningsRepay was 0", async () => {
                expect(returnValues.earningsRepay).to.eq(parseUnits("0"));
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
    describe("GIVEN a 2x borrowMP of 5000 (250 fees earned) = 10000 + 500 in fees", () => {
      const fiveDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 5;

      beforeEach(async () => {
        poolAccountingEnv.switchWallet(laura);
        await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await poolAccountingEnv.moveInTime(fiveDaysToMaturity);
        await poolAccountingEnv.borrowMP(nextPoolID, "5000");
        await poolAccountingEnv.borrowMP(nextPoolID, "5000");
        mp = await poolAccountingHarness.maturityPools(nextPoolID);
      });

      it("THEN fees (all) should be 500", () => {
        expect(
          mp.earningsMP.add(mp.earningsSP).add(mp.earningsUnassigned)
        ).to.eq(parseUnits("500"));
      });

      describe("WHEN an early repayment of 5250", () => {
        beforeEach(async () => {
          await poolAccountingEnv.repayMP(nextPoolID, "5250");
          returnValues = await poolAccountingHarness.returnValues();
          mp = await poolAccountingHarness.maturityPools(nextPoolID);
        });
        it("THEN borrowed is 5000", async () => {
          expect(mp.borrowed).to.eq(parseUnits("5000"));
        });
        it("THEN fees have been shared with the early repayment (sum still 500)", async () => {
          const earningsDistributed = parseUnits("250").sub(
            returnValues.spareAmount
          );
          expect(
            mp.earningsMP
              .add(mp.earningsSP)
              .add(mp.earningsUnassigned)
              .add(returnValues.spareAmount)
              .add(earningsDistributed)
          ).to.eq(parseUnits("500"));
        });
        it("THEN spareAmount is NOT 0 (got a discount)", async () => {
          expect(returnValues.spareAmount).to.not.eq(parseUnits("0"));
        });

        describe("AND WHEN an early repayment of 5250", () => {
          beforeEach(async () => {
            await poolAccountingEnv.repayMP(nextPoolID, "5250");
            returnValues = await poolAccountingHarness.returnValues();
            mp = await poolAccountingHarness.maturityPools(nextPoolID);
          });
          it("THEN borrowed is 0", async () => {
            expect(mp.borrowed).to.eq(0);
          });
          it("THEN interests are all 0", async () => {
            expect(
              mp.earningsMP.add(mp.earningsSP).add(mp.earningsUnassigned)
            ).to.eq(0);
          });
          it("THEN suppliedSP is 0", async () => {
            expect(mp.suppliedSP).to.eq(0);
          });
          it("THEN spareAmount is NOT 0 (got a discount)", async () => {
            expect(returnValues.spareAmount).to.not.eq(parseUnits("0"));
          });
        });
      });
    });

    describe("GIVEN a borrowMP of 5000 (250 fees earned) AND a depositMP of 5000", () => {
      const fiveDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 5;

      beforeEach(async () => {
        poolAccountingEnv.switchWallet(laura);
        await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await poolAccountingEnv.moveInTime(fiveDaysToMaturity);
        await poolAccountingEnv.borrowMP(nextPoolID, "5000");
        await poolAccountingEnv.depositMP(nextPoolID, "5000");
        mp = await poolAccountingHarness.maturityPools(nextPoolID);
      });

      it("THEN fees (all) should be 250", () => {
        expect(
          mp.earningsMP.add(mp.earningsSP).add(mp.earningsUnassigned)
        ).to.eq(parseUnits("250"));
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
        it("THEN fees have been paid with the early repayment (= 0)", async () => {
          expect(
            mp.earningsMP.add(mp.earningsSP).add(mp.earningsUnassigned)
          ).to.eq(parseUnits("0"));
        });
        it("THEN spareAmount is 0 (didn't get a discount since it was gotten all before)", async () => {
          expect(returnValues.spareAmount).to.eq(parseUnits("0"));
        });
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
