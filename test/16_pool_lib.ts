import { expect } from "chai";
import { BigNumber } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { ExaTime } from "./exactlyUtils";
import { PoolEnv } from "./poolEnv";

describe("Pool Management Library", () => {
  let poolEnv: PoolEnv;
  let mp: any;
  let scaledDebt: any;
  const mockMaxDebt = "5000";

  describe("GIVEN a clean maturity pool", () => {
    beforeEach(async () => {
      poolEnv = await PoolEnv.create();
    });

    describe("depositMoney & borrowMoney", () => {
      describe("WHEN 100 tokens are deposited", () => {
        beforeEach(async () => {
          await poolEnv.depositMoney("100");
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'borrowed' is 0", async () => {
          expect(mp.borrowed).to.equal(parseUnits("0"));
        });
        it("THEN the pool 'supplied' is 100", async () => {
          expect(mp.supplied).to.equal(parseUnits("100"));
        });
        it("THEN the pool 'suppliedSP' is 0", async () => {
          expect(mp.suppliedSP).to.equal(parseUnits("0"));
        });
        it("THEN the pool 'earningsUnassigned' are 0", async () => {
          expect(mp.earningsUnassigned).to.equal(parseUnits("0"));
        });
        it("THEN the smartPoolDebtReduction that is returned is 0", async () => {
          const smartPoolDebtReductionReturned = await poolEnv.getMpHarness().smartPoolDebtReduction();
          expect(smartPoolDebtReductionReturned).to.equal(parseUnits("0"));
        });
        describe("AND WHEN 80 tokens are taken out", () => {
          beforeEach(async () => {
            await poolEnv.borrowMoney("80", mockMaxDebt);
            mp = await poolEnv.mpHarness.maturityPool();
          });

          it("THEN the newDebtSP that is returned is 0", async () => {
            const newDebtSpReturned = await poolEnv.getMpHarness().newDebtSP();
            expect(newDebtSpReturned).to.equal(parseUnits("0"));
          });
          it("THEN the pool 'borrowed' is 80", async () => {
            expect(mp.borrowed).to.equal(parseUnits("80"));
          });
          it("THEN the pool 'supplied' is 100", async () => {
            expect(mp.supplied).to.equal(parseUnits("100"));
          });
          it("THEN the pool 'suppliedSP' is 0", async () => {
            expect(mp.suppliedSP).to.equal(parseUnits("0"));
          });
          describe("AND WHEN another 20 tokens are taken out", () => {
            beforeEach(async () => {
              await poolEnv.borrowMoney("20", mockMaxDebt);
              mp = await poolEnv.mpHarness.maturityPool();
            });

            it("THEN the newDebtSP that is returned is 0", async () => {
              const newDebtSpReturned = await poolEnv.getMpHarness().newDebtSP();
              expect(newDebtSpReturned).to.equal(parseUnits("0"));
            });
            it("THEN the pool 'borrowed' is 100", async () => {
              expect(mp.borrowed).to.equal(parseUnits("100"));
            });
            it("THEN the pool 'supplied' is 100", async () => {
              expect(mp.supplied).to.equal(parseUnits("100"));
            });
            it("THEN the pool 'suppliedSP' is 0", async () => {
              expect(mp.suppliedSP).to.equal(parseUnits("0"));
            });
            describe("AND WHEN more tokens are taken out than the max sp debt", () => {
              let tx: any;
              beforeEach(async () => {
                tx = poolEnv.borrowMoney("5000", "1000");
              });
              it("THEN it reverts with error INSUFFICIENT_PROTOCOL_LIQUIDITY", async () => {
                await expect(tx).to.be.revertedWith("InsufficientProtocolLiquidity()");
              });
            });
            describe("AND WHEN the exact amount of max sp debt is taken out", () => {
              let tx: any;
              beforeEach(async () => {
                tx = poolEnv.borrowMoney("1000", "1000");
              });
              it("THEN it should not revert", async () => {
                await expect(tx).to.not.be.reverted;
              });
            });
            describe("AND WHEN 50 tokens are taken out", () => {
              beforeEach(async () => {
                await poolEnv.borrowMoney("50", mockMaxDebt);
                mp = await poolEnv.mpHarness.maturityPool();
              });

              it("THEN the newDebtSP that is returned is 0", async () => {
                const newDebtSpReturned = await poolEnv.getMpHarness().newDebtSP();
                expect(newDebtSpReturned).to.equal(parseUnits("50"));
              });
              it("THEN the pool 'borrowed' is 150", async () => {
                expect(mp.borrowed).to.equal(parseUnits("150"));
              });
              it("THEN the pool 'supplied' is 100", async () => {
                expect(mp.supplied).to.equal(parseUnits("100"));
              });
              it("THEN the pool 'suppliedSP' is 50", async () => {
                expect(mp.suppliedSP).to.equal(parseUnits("50"));
              });
            });
          });
        });
      });
    });

    describe("addFee & removeFee", () => {
      describe("WHEN 100 fees are added", () => {
        beforeEach(async () => {
          await poolEnv.addFee("100");
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'earningsUnassigned' are 100", async () => {
          expect(mp.earningsUnassigned).to.equal(parseUnits("100"));
        });
        describe("AND WHEN 50 fees are removed", () => {
          beforeEach(async () => {
            await poolEnv.removeFee("50");
            mp = await poolEnv.mpHarness.maturityPool();
          });
          it("THEN the pool 'earningsUnassigned' are 50", async () => {
            expect(mp.earningsUnassigned).to.equal(parseUnits("50"));
          });
          describe("AND WHEN another 50 fees are removed", () => {
            beforeEach(async () => {
              await poolEnv.removeFee("50");
              mp = await poolEnv.mpHarness.maturityPool();
            });
            it("THEN the pool 'earningsUnassigned' are 0", async () => {
              expect(mp.earningsUnassigned).to.equal(parseUnits("0"));
            });
          });
        });
      });
    });

    describe("accrueEarnings", () => {
      describe("GIVEN a fresh maturity date in 10 days", () => {
        let exaTime: ExaTime;
        let now: number;
        let sixDays: number;
        let tenDays: number;
        beforeEach(async () => {
          exaTime = new ExaTime();
          now = exaTime.timestamp;
          tenDays = now + exaTime.ONE_DAY * 10;
          sixDays = now + exaTime.ONE_DAY * 6;

          await poolEnv.setNextTimestamp(now);
          await poolEnv.accrueEarnings(tenDays);
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'earningsUnassigned' are 0", async () => {
          expect(mp.earningsUnassigned).to.equal(0);
        });
        it("THEN the pool 'lastAccrue' is now", async () => {
          expect(mp.lastAccrue).to.equal(now);
        });
        it("THEN the last earnings SP is 0", async () => {
          const lastEarningsSP = await poolEnv.mpHarness.lastEarningsSP();
          expect(lastEarningsSP).to.equal(0);
        });

        describe("AND GIVEN that we add 100 in fees and 6 days went by", () => {
          beforeEach(async () => {
            await poolEnv.addFee("100");
            await poolEnv.setNextTimestamp(sixDays);
            await poolEnv.accrueEarnings(tenDays);
            mp = await poolEnv.mpHarness.maturityPool();
          });

          it("THEN the pool 'earningsUnassigned' are 40", async () => {
            expect(mp.earningsUnassigned).to.equal(parseUnits("40"));
          });
          it("THEN the pool 'lastAccrue' is fiveDays", async () => {
            expect(mp.lastAccrue).to.equal(sixDays);
          });
          it("THEN the last earnings SP is 60", async () => {
            const lastEarningsSP = await poolEnv.mpHarness.lastEarningsSP();
            expect(lastEarningsSP).to.equal(parseUnits("60"));
          });

          describe("AND GIVEN that another 150 seconds go by", () => {
            beforeEach(async () => {
              await poolEnv.setNextTimestamp(sixDays + exaTime.ONE_SECOND * 150);
              await poolEnv.accrueEarnings(tenDays);
              mp = await poolEnv.mpHarness.maturityPool();
            });

            it("THEN the pool 'earningsUnassigned' are ~= 39.98263", async () => {
              // 10 / 86400           = 0.00011574074 (unassigned earnings per second)
              // 0.00011574074 * 150  = 0.01736111111 (earnings accrued)
              // 40 - 0.01736111111   = 39.9826388889 (unassigned earnings left)
              expect(mp.earningsUnassigned).to.closeTo(parseUnits("39.9826388"), parseUnits("00.0000001").toNumber());
            });
            it("THEN the pool 'lastAccrue' is tenDays", async () => {
              expect(mp.lastAccrue).to.equal(sixDays + exaTime.ONE_SECOND * 150);
            });
            it("THEN the last earnings SP is ~= 0.017361", async () => {
              const lastEarningsSP = await poolEnv.mpHarness.lastEarningsSP();
              expect(lastEarningsSP).to.closeTo(parseUnits("0.0173611"), parseUnits("0.0000001").toNumber());
            });
          });

          describe("AND GIVEN that we go over +1 day the maturity date", () => {
            beforeEach(async () => {
              await poolEnv.setNextTimestamp(tenDays + exaTime.ONE_DAY);
              await poolEnv.accrueEarnings(tenDays);
              mp = await poolEnv.mpHarness.maturityPool();
            });

            it("THEN the pool 'earningsUnassigned' are 0", async () => {
              expect(mp.earningsUnassigned).to.equal(0);
            });
            it("THEN the pool 'lastAccrue' is tenDays", async () => {
              expect(mp.lastAccrue).to.equal(tenDays);
            });
            it("THEN the last earnings SP is 40 (the remaining)", async () => {
              const lastEarningsSP = await poolEnv.mpHarness.lastEarningsSP();
              expect(lastEarningsSP).to.equal(parseUnits("40"));
            });

            describe("AND GIVEN that we go over another +1 day the maturity date", () => {
              beforeEach(async () => {
                await poolEnv.setNextTimestamp(tenDays + exaTime.ONE_DAY * 2);
                await poolEnv.accrueEarnings(tenDays);
                mp = await poolEnv.mpHarness.maturityPool();
              });

              it("THEN the pool 'earningsUnassigned' are 0", async () => {
                expect(mp.earningsUnassigned).to.equal(0);
              });
              it("THEN the pool 'lastAccrue' is tenDays", async () => {
                expect(mp.lastAccrue).to.equal(tenDays);
              });
              it("THEN the last earnings SP is 0", async () => {
                const lastEarningsSP = await poolEnv.mpHarness.lastEarningsSP();
                expect(lastEarningsSP).to.equal(parseUnits("0"));
              });
            });
          });

          describe("AND GIVEN that we remove 20 fees and we go over +1 day the maturity date", () => {
            beforeEach(async () => {
              await poolEnv.removeFee("20");
              await poolEnv.setNextTimestamp(tenDays + exaTime.ONE_DAY);
              await poolEnv.accrueEarnings(tenDays);
              mp = await poolEnv.mpHarness.maturityPool();
            });

            it("THEN the pool 'earningsUnassigned' are 0", async () => {
              expect(mp.earningsUnassigned).to.equal(0);
            });
            it("THEN the pool 'lastAccrue' is tenDays", async () => {
              expect(mp.lastAccrue).to.equal(tenDays);
            });
            it("THEN the last earnings SP is 20 (40 were remaining - 20 removed)", async () => {
              const lastEarningsSP = await poolEnv.mpHarness.lastEarningsSP();
              expect(lastEarningsSP).to.equal(parseUnits("20"));
            });
          });
        });
      });
    });

    describe("repayMoney", () => {
      describe("WHEN 100 tokens are taken out", () => {
        beforeEach(async () => {
          await poolEnv.borrowMoney("100", mockMaxDebt);
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'borrowed' is 100", async () => {
          expect(mp.borrowed).to.equal(parseUnits("100"));
        });
        it("THEN the newDebtSP that is returned is 100", async () => {
          const newDebtSpReturned = await poolEnv.getMpHarness().newDebtSP();
          expect(newDebtSpReturned).to.equal(parseUnits("100"));
        });
        describe("AND WHEN 50 tokens are repaid", () => {
          beforeEach(async () => {
            await poolEnv.repayMoney("50");
            mp = await poolEnv.mpHarness.maturityPool();
          });

          it("THEN the pool 'borrowed' is 50", async () => {
            expect(mp.borrowed).to.equal(parseUnits("50"));
          });
          it("THEN the pool 'suppliedSP' is 50", async () => {
            expect(mp.suppliedSP).to.equal(parseUnits("50"));
          });
          it("THEN the smartPoolDebtReduction that is returned is 50", async () => {
            const smartPoolDebtReductionReturned = await poolEnv.getMpHarness().smartPoolDebtReduction();
            expect(smartPoolDebtReductionReturned).to.equal(parseUnits("50"));
          });
          describe("AND WHEN another 50 tokens are repaid", () => {
            beforeEach(async () => {
              await poolEnv.repayMoney("50");
              mp = await poolEnv.mpHarness.maturityPool();
            });

            it("THEN the pool 'borrowed' is 0", async () => {
              expect(mp.borrowed).to.equal(parseUnits("0"));
            });
            it("THEN the pool 'suppliedSP' is 0", async () => {
              expect(mp.suppliedSP).to.equal(parseUnits("0"));
            });
            it("THEN the smartPoolDebtReduction that is returned is 50", async () => {
              const smartPoolDebtReductionReturned = await poolEnv.getMpHarness().smartPoolDebtReduction();
              expect(smartPoolDebtReductionReturned).to.equal(parseUnits("50"));
            });
          });
        });
      });
    });

    describe("withdrawMoney", () => {
      describe("GIVEN 100 tokens are deposited", () => {
        beforeEach(async () => {
          await poolEnv.depositMoney("100");
        });
        describe("WHEN 50 tokens are withdrawn", () => {
          beforeEach(async () => {
            await poolEnv.withdrawMoney("50", mockMaxDebt);
            mp = await poolEnv.mpHarness.maturityPool();
          });

          it("THEN the pool 'supplied' is 50", async () => {
            expect(mp.supplied).to.equal(parseUnits("50"));
          });
          it("THEN the newDebtSP that is returned is 0", async () => {
            const newDebtSpReturned = await poolEnv.getMpHarness().newDebtSP();
            expect(newDebtSpReturned).to.equal(parseUnits("0"));
          });
          describe("AND GIVEN another 100 tokens are taken out", () => {
            beforeEach(async () => {
              await poolEnv.borrowMoney("100", mockMaxDebt);
            });
            describe("WHEN another 50 tokens are withdrawn", () => {
              beforeEach(async () => {
                await poolEnv.withdrawMoney("50", mockMaxDebt);
                mp = await poolEnv.mpHarness.maturityPool();
              });

              it("THEN the pool 'supplied' is 0", async () => {
                expect(mp.supplied).to.equal(parseUnits("0"));
              });
              it("THEN the newDebtSP that is returned is 50", async () => {
                const newDebtSpReturned = await poolEnv.getMpHarness().newDebtSP();
                expect(newDebtSpReturned).to.equal(parseUnits("50"));
              });
            });
            describe("AND WHEN more tokens are taken out than the max sp debt", () => {
              let tx: any;
              beforeEach(async () => {
                tx = poolEnv.withdrawMoney("50", "49");
              });
              it("THEN it reverts with error INSUFFICIENT_PROTOCOL_LIQUIDITY", async () => {
                await expect(tx).to.be.revertedWith("InsufficientProtocolLiquidity()");
              });
            });
            describe("AND WHEN the exact amount of max sp debt is taken out", () => {
              let tx: any;
              beforeEach(async () => {
                tx = poolEnv.withdrawMoney("50", "100");
              });
              it("THEN it should not revert", async () => {
                await expect(tx).to.not.be.reverted;
              });
            });
          });
          describe("AND WHEN another 50 tokens are withdrawn", () => {
            beforeEach(async () => {
              await poolEnv.withdrawMoney("50", mockMaxDebt);
              mp = await poolEnv.mpHarness.maturityPool();
            });

            it("THEN the pool 'supplied' is 0", async () => {
              expect(mp.supplied).to.equal(parseUnits("0"));
            });
            it("THEN the newDebtSP that is returned is 0", async () => {
              const newDebtSpReturned = await poolEnv.getMpHarness().newDebtSP();
              expect(newDebtSpReturned).to.equal(parseUnits("0"));
            });
          });
        });
      });
    });

    describe("scaleProportionally", () => {
      describe("GIVEN a 100 scaledDebtPrincipal AND a 100 scaledDebtFee", () => {
        describe("WHEN 50 is proportionally scaled", () => {
          beforeEach(async () => {
            await poolEnv.scaleProportionally("100", "100", "50");
            scaledDebt = await poolEnv.getMpHarness().scaledDebt();
          });

          it("THEN the scaledDebtPrincipal is 25", async () => {
            expect(scaledDebt.principal).to.equal(parseUnits("25"));
          });
          it("THEN the scaledDebtFee is 25", async () => {
            expect(scaledDebt.fee).to.equal(parseUnits("25"));
          });
          describe("AND WHEN another 5 is proportionally scaled", () => {
            beforeEach(async () => {
              await poolEnv.scaleProportionally("25", "25", "5");
              scaledDebt = await poolEnv.getMpHarness().scaledDebt();
            });

            it("THEN the scaledDebtPrincipal is 2.5", async () => {
              expect(scaledDebt.principal).to.equal(parseUnits("2.5"));
            });
            it("THEN the scaledDebtFee is 2.5", async () => {
              expect(scaledDebt.fee).to.equal(parseUnits("2.5"));
            });
          });
        });
      });
      describe("GIVEN a 100 scaledDebtPrincipal AND a 0 scaledDebtFee", () => {
        describe("WHEN 50 is proportionally scaled", () => {
          beforeEach(async () => {
            await poolEnv.scaleProportionally("100", "0", "50");
            scaledDebt = await poolEnv.getMpHarness().scaledDebt();
          });

          it("THEN the scaledDebtPrincipal is 50", async () => {
            expect(scaledDebt.principal).to.equal(parseUnits("50"));
          });
          it("THEN the scaledDebtFee is 0", async () => {
            expect(scaledDebt.fee).to.equal(parseUnits("0"));
          });
        });
      });
      describe("GIVEN a 0 scaledDebtPrincipal AND a 50 scaledDebtFee", () => {
        describe("WHEN 50 is proportionally scaled", () => {
          beforeEach(async () => {
            await poolEnv.scaleProportionally("0", "100", "50");
            scaledDebt = await poolEnv.getMpHarness().scaledDebt();
          });

          it("THEN the scaledDebtPrincipal is 0", async () => {
            expect(scaledDebt.principal).to.equal(parseUnits("0"));
          });
          it("THEN the scaledDebtFee is 50", async () => {
            expect(scaledDebt.fee).to.equal(parseUnits("50"));
          });
        });
      });
      describe("GIVEN a 0 scaledDebtPrincipal AND a 100 scaledDebtFee", () => {
        describe("WHEN 100 is proportionally scaled", () => {
          beforeEach(async () => {
            await poolEnv.scaleProportionally("0", "100", "100");
            scaledDebt = await poolEnv.getMpHarness().scaledDebt();
          });

          it("THEN the scaledDebtPrincipal is 0", async () => {
            expect(scaledDebt.principal).to.equal(parseUnits("0"));
          });
          it("THEN the scaledDebtFee is 100", async () => {
            expect(scaledDebt.fee).to.equal(parseUnits("100"));
          });
        });
      });
    });

    describe("reduceProportionally", () => {
      describe("GIVEN a 100 scaledDebtPrincipal AND a 100 scaledDebtFee", () => {
        describe("WHEN 50 is proportionally reduced", () => {
          beforeEach(async () => {
            await poolEnv.reduceProportionally("100", "100", "50");
            scaledDebt = await poolEnv.getMpHarness().scaledDebt();
          });

          it("THEN the scaledDebtPrincipal is 75", async () => {
            expect(scaledDebt.principal).to.equal(parseUnits("75"));
          });
          it("THEN the scaledDebtFee is 75", async () => {
            expect(scaledDebt.fee).to.equal(parseUnits("75"));
          });
          describe("AND WHEN another 150 is proportionally reduced", () => {
            beforeEach(async () => {
              await poolEnv.reduceProportionally("75", "75", "150");
              scaledDebt = await poolEnv.getMpHarness().scaledDebt();
            });

            it("THEN the scaledDebtPrincipal is 0", async () => {
              expect(scaledDebt.principal).to.equal(parseUnits("0"));
            });
            it("THEN the scaledDebtFee is 0", async () => {
              expect(scaledDebt.fee).to.equal(parseUnits("0"));
            });
          });
        });
      });
      describe("GIVEN a 100 scaledDebtPrincipal AND a 0 scaledDebtFee", () => {
        describe("WHEN 50 is proportionally reduced", () => {
          beforeEach(async () => {
            await poolEnv.reduceProportionally("100", "0", "50");
            scaledDebt = await poolEnv.getMpHarness().scaledDebt();
          });

          it("THEN the scaledDebtPrincipal is 50", async () => {
            expect(scaledDebt.principal).to.equal(parseUnits("50"));
          });
          it("THEN the scaledDebtFee is 0", async () => {
            expect(scaledDebt.fee).to.equal(parseUnits("0"));
          });
        });
      });
      describe("GIVEN a 0 scaledDebtPrincipal AND a 100 scaledDebtFee", () => {
        describe("WHEN 100 is proportionally reduced", () => {
          beforeEach(async () => {
            await poolEnv.reduceProportionally("0", "100", "100");
            scaledDebt = await poolEnv.getMpHarness().scaledDebt();
          });

          it("THEN the scaledDebtPrincipal is 0", async () => {
            expect(scaledDebt.principal).to.equal(parseUnits("0"));
          });
          it("THEN the scaledDebtFee is 0", async () => {
            expect(scaledDebt.fee).to.equal(parseUnits("0"));
          });
        });
      });
    });

    describe("setMaturity", () => {
      let newUserBorrows: number;
      const userBorrowsWith21DayMaturity = 4_296_781_696;
      const userBorrowsWith21And35DayMaturity = 21_476_650_880;
      const userBorrowsWith7And21And35DayMaturity = 90_194_918_016;

      describe("GIVEN a 21 days maturity is added to the userBorrows", () => {
        beforeEach(async () => {
          await poolEnv.setMaturity(0, 86_400 * 21);
          newUserBorrows = await poolEnv.mpHarness.newUserBorrows();
        });
        it("THEN newUserBorrows is userBorrowsWith21DayMaturity", async () => {
          expect(newUserBorrows).to.equal(userBorrowsWith21DayMaturity);
        });
        describe("AND GIVEN another 21 days maturity is added to the userBorrows", () => {
          beforeEach(async () => {
            await poolEnv.setMaturity(userBorrowsWith21DayMaturity, 86_400 * 21);
            newUserBorrows = await poolEnv.mpHarness.newUserBorrows();
          });
          it("THEN newUserBorrows is equal to the previous value", async () => {
            expect(newUserBorrows).to.equal(userBorrowsWith21DayMaturity);
          });
        });
        describe("AND GIVEN a 35 days maturity is added to the userBorrows", () => {
          beforeEach(async () => {
            await poolEnv.setMaturity(userBorrowsWith21DayMaturity, 86_400 * 35);
            newUserBorrows = await poolEnv.mpHarness.newUserBorrows();
          });
          it("THEN newUserBorrows has the result of both maturities", async () => {
            expect(newUserBorrows).to.equal(userBorrowsWith21And35DayMaturity);
          });
          describe("AND GIVEN a 7 days maturity is added to the userBorrows", () => {
            beforeEach(async () => {
              await poolEnv.setMaturity(userBorrowsWith21And35DayMaturity, 86_400 * 7);
              newUserBorrows = await poolEnv.mpHarness.newUserBorrows();
            });
            it("THEN newUserBorrows has the result of the three maturities added", async () => {
              expect(newUserBorrows).to.equal(userBorrowsWith7And21And35DayMaturity);
            });
            describe("AND GIVEN the 7 days maturity is removed from the userBorrows", () => {
              beforeEach(async () => {
                await poolEnv.clearMaturity(userBorrowsWith7And21And35DayMaturity, 86_400 * 7);
                newUserBorrows = await poolEnv.mpHarness.newUserBorrows();
              });
              it("THEN newUserBorrows has the result of the 21 and 35 days maturity", async () => {
                expect(newUserBorrows).to.equal(userBorrowsWith21And35DayMaturity);
              });
              describe("AND GIVEN the 7 days maturity is removed again from the userBorrows", () => {
                beforeEach(async () => {
                  await poolEnv.clearMaturity(userBorrowsWith21And35DayMaturity, 86_400 * 7);
                  newUserBorrows = await poolEnv.mpHarness.newUserBorrows();
                });
                it("THEN newUserBorrows has the result of the 21 and 35 days maturity", async () => {
                  expect(newUserBorrows).to.equal(userBorrowsWith21And35DayMaturity);
                });
              });
              describe("AND GIVEN the 35 days maturity is removed from the userBorrows", () => {
                beforeEach(async () => {
                  await poolEnv.clearMaturity(userBorrowsWith21And35DayMaturity, 86_400 * 35);
                  newUserBorrows = await poolEnv.mpHarness.newUserBorrows();
                });
                it("THEN newUserBorrows has the result of the 21 days maturity", async () => {
                  expect(newUserBorrows).to.equal(userBorrowsWith21DayMaturity);
                });
                describe("AND GIVEN the 35 days maturity is removed again from the userBorrows", () => {
                  beforeEach(async () => {
                    await poolEnv.clearMaturity(userBorrowsWith21DayMaturity, 86_400 * 35);
                    newUserBorrows = await poolEnv.mpHarness.newUserBorrows();
                  });
                  it("THEN newUserBorrows has the result of the 21 days maturity", async () => {
                    expect(newUserBorrows).to.equal(userBorrowsWith21DayMaturity);
                  });
                });
                describe("AND GIVEN the 21 days maturity is removed from the userBorrows", () => {
                  beforeEach(async () => {
                    await poolEnv.clearMaturity(userBorrowsWith21DayMaturity, 86_400 * 21);
                    newUserBorrows = await poolEnv.mpHarness.newUserBorrows();
                  });
                  it("THEN newUserBorrows has the result of the 21 days maturity", async () => {
                    expect(newUserBorrows).to.equal(0);
                  });
                });
              });
            });
            describe("AND GIVEN the 7a days maturity is removed from the userBorrows", () => {
              beforeEach(async () => {
                await poolEnv.clearMaturity(userBorrowsWith7And21And35DayMaturity, 86_400 * 7);
                newUserBorrows = await poolEnv.mpHarness.newUserBorrows();
              });
              it("THEN newUserBorrows has the result of the 21 and 35 days maturity", async () => {
                expect(newUserBorrows).to.equal(userBorrowsWith21And35DayMaturity);
              });
            });
          });
        });
      });
      describe("GIVEN a 7 days maturity is tried to remove from the userBorrows that it's 0", () => {
        beforeEach(async () => {
          await poolEnv.clearMaturity(0, 86_400 * 7);
          newUserBorrows = await poolEnv.mpHarness.newUserBorrows();
        });
        it("THEN newUserBorrows should still be 0", async () => {
          expect(newUserBorrows).to.equal(0);
        });
      });
    });

    describe("distributeEarningsAccordingly", () => {
      let lastEarningsSP: BigNumber;
      let lastEarningsTreasury: BigNumber;
      describe("GIVEN 100 earnings, 1000 supplySP and 800 amountFunded", () => {
        beforeEach(async () => {
          await poolEnv.distributeEarningsAccordingly("100", "1000", "800");
          lastEarningsSP = await poolEnv.mpHarness.lastEarningsSP();
          lastEarningsTreasury = await poolEnv.mpHarness.lastEarningsTreasury();
        });

        it("THEN lastEarningsSP is 100", async () => {
          expect(lastEarningsSP).to.equal(parseUnits("100"));
        });
        it("THEN lastEarningsTreasury is 0", async () => {
          expect(lastEarningsTreasury).to.equal(0);
        });
      });

      describe("GIVEN 100 earnings, 400 supplySP and 800 amountFunded", () => {
        beforeEach(async () => {
          await poolEnv.distributeEarningsAccordingly("100", "400", "800");
          lastEarningsSP = await poolEnv.mpHarness.lastEarningsSP();
          lastEarningsTreasury = await poolEnv.mpHarness.lastEarningsTreasury();
        });

        it("THEN lastEarningsSP is 50", async () => {
          expect(lastEarningsSP).to.equal(parseUnits("50"));
        });
        it("THEN lastEarningsTreasury is 50", async () => {
          expect(lastEarningsTreasury).to.equal(parseUnits("50"));
        });
      });

      describe("GIVEN 100 earnings, 0 supplySP and 800 amountFunded", () => {
        beforeEach(async () => {
          await poolEnv.distributeEarningsAccordingly("100", "0", "800");
          lastEarningsSP = await poolEnv.mpHarness.lastEarningsSP();
          lastEarningsTreasury = await poolEnv.mpHarness.lastEarningsTreasury();
        });

        it("THEN lastEarningsSP is 0", async () => {
          expect(lastEarningsSP).to.equal(0);
        });
        it("THEN lastEarningsTreasury is 100", async () => {
          expect(lastEarningsTreasury).to.equal(parseUnits("100"));
        });
      });

      describe("GIVEN 0 earnings, 0 supplySP and 800 amountFunded", () => {
        beforeEach(async () => {
          await poolEnv.distributeEarningsAccordingly("0", "0", "800");
          lastEarningsSP = await poolEnv.mpHarness.lastEarningsSP();
          lastEarningsTreasury = await poolEnv.mpHarness.lastEarningsTreasury();
        });

        it("THEN lastEarningsSP is 0", async () => {
          expect(lastEarningsSP).to.equal(0);
        });
        it("THEN lastEarningsTreasury is 0", async () => {
          expect(lastEarningsTreasury).to.equal(0);
        });
      });
    });
  });
});
