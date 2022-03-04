import { expect } from "chai";
import { BigNumber } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { errorGeneric, ExaTime, ProtocolError } from "./exactlyUtils";
import { PoolEnv } from "./poolEnv";

describe("Pool Management Library", () => {
  let poolEnv: PoolEnv;
  let mp: any;
  let scaledDebt: any;
  const mockedMaxDebt = "5000";

  describe("GIVEN a clean maturity pool", () => {
    beforeEach(async () => {
      poolEnv = await PoolEnv.create();
    });

    describe("depositMoney & borrowMoney", async () => {
      describe("WHEN 100 tokens are deposited", async () => {
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
          const smartPoolDebtReductionReturned = await poolEnv
            .getMpHarness()
            .smartPoolDebtReduction();
          expect(smartPoolDebtReductionReturned).to.equal(parseUnits("0"));
        });
        describe("AND WHEN 80 tokens are taken out", async () => {
          beforeEach(async () => {
            await poolEnv.borrowMoney("80", mockedMaxDebt);
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
          describe("AND WHEN another 20 tokens are taken out", async () => {
            beforeEach(async () => {
              await poolEnv.borrowMoney("20", mockedMaxDebt);
              mp = await poolEnv.mpHarness.maturityPool();
            });

            it("THEN the newDebtSP that is returned is 0", async () => {
              const newDebtSpReturned = await poolEnv
                .getMpHarness()
                .newDebtSP();
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
            describe("AND WHEN more tokens are taken out than the max sp debt", async () => {
              let tx: any;
              beforeEach(async () => {
                tx = poolEnv.borrowMoney("5000", "1000");
              });
              it("THEN it reverts with error INSUFFICIENT_PROTOCOL_LIQUIDITY", async () => {
                await expect(tx).to.be.revertedWith(
                  errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
                );
              });
            });
            describe("AND WHEN 50 tokens are taken out", async () => {
              beforeEach(async () => {
                await poolEnv.borrowMoney("50", mockedMaxDebt);
                mp = await poolEnv.mpHarness.maturityPool();
              });

              it("THEN the newDebtSP that is returned is 0", async () => {
                const newDebtSpReturned = await poolEnv
                  .getMpHarness()
                  .newDebtSP();
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

    describe("addFee & removeFee", async () => {
      describe("WHEN 100 fees are added", async () => {
        beforeEach(async () => {
          await poolEnv.addFee("100");
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'earningsUnassigned' are 100", async () => {
          expect(mp.earningsUnassigned).to.equal(parseUnits("100"));
        });
        describe("AND WHEN 50 fees are removed", async () => {
          beforeEach(async () => {
            await poolEnv.removeFee("50");
            mp = await poolEnv.mpHarness.maturityPool();
          });
          it("THEN the pool 'earningsUnassigned' are 50", async () => {
            expect(mp.earningsUnassigned).to.equal(parseUnits("50"));
          });
          describe("AND WHEN another 50 fees are removed", async () => {
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

    describe("accrueEarnings", async () => {
      describe("GIVEN a fresh maturity date in 10 days", async () => {
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

        describe("AND GIVEN that we add 100 in fees and 6 days went by", async () => {
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

          describe("AND GIVEN that another 150 seconds go by", async () => {
            beforeEach(async () => {
              await poolEnv.setNextTimestamp(
                sixDays + exaTime.ONE_SECOND * 150
              );
              await poolEnv.accrueEarnings(tenDays);
              mp = await poolEnv.mpHarness.maturityPool();
            });

            it("THEN the pool 'earningsUnassigned' are ~= 39.98263", async () => {
              // 10 / 86400           = 0.00011574074 (unassigned earnings per second)
              // 0.00011574074 * 150  = 0.01736111111 (earnings accrued)
              // 40 - 0.01736111111   = 39.9826388889 (unassigned earnings left)
              expect(mp.earningsUnassigned).to.closeTo(
                parseUnits("39.9826388"),
                parseUnits("00.0000001").toNumber()
              );
            });
            it("THEN the pool 'lastAccrue' is tenDays", async () => {
              expect(mp.lastAccrue).to.equal(
                sixDays + exaTime.ONE_SECOND * 150
              );
            });
            it("THEN the last earnings SP is ~= 0.017361", async () => {
              const lastEarningsSP = await poolEnv.mpHarness.lastEarningsSP();
              expect(lastEarningsSP).to.closeTo(
                parseUnits("0.0173611"),
                parseUnits("0.0000001").toNumber()
              );
            });
          });

          describe("AND GIVEN that we go over +1 day the maturity date", async () => {
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

            describe("AND GIVEN that we go over another +1 day the maturity date", async () => {
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

          describe("AND GIVEN that we remove 20 fees and we go over +1 day the maturity date", async () => {
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

    describe("repayMoney", async () => {
      describe("WHEN 100 tokens are taken out", async () => {
        beforeEach(async () => {
          await poolEnv.borrowMoney("100", mockedMaxDebt);
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'borrowed' is 100", async () => {
          expect(mp.borrowed).to.equal(parseUnits("100"));
        });
        it("THEN the newDebtSP that is returned is 100", async () => {
          const newDebtSpReturned = await poolEnv.getMpHarness().newDebtSP();
          expect(newDebtSpReturned).to.equal(parseUnits("100"));
        });
        describe("AND WHEN 50 tokens are repaid", async () => {
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
            const smartPoolDebtReductionReturned = await poolEnv
              .getMpHarness()
              .smartPoolDebtReduction();
            expect(smartPoolDebtReductionReturned).to.equal(parseUnits("50"));
          });
          describe("AND WHEN another 50 tokens are repaid", async () => {
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
              const smartPoolDebtReductionReturned = await poolEnv
                .getMpHarness()
                .smartPoolDebtReduction();
              expect(smartPoolDebtReductionReturned).to.equal(parseUnits("50"));
            });
          });
        });
      });
    });

    describe("withdrawMoney", async () => {
      describe("GIVEN 100 tokens are deposited", async () => {
        beforeEach(async () => {
          await poolEnv.depositMoney("100");
        });
        describe("WHEN 50 tokens are withdrawn", async () => {
          beforeEach(async () => {
            await poolEnv.withdrawMoney("50", mockedMaxDebt);
            mp = await poolEnv.mpHarness.maturityPool();
          });

          it("THEN the pool 'supplied' is 50", async () => {
            expect(mp.supplied).to.equal(parseUnits("50"));
          });
          it("THEN the newDebtSP that is returned is 0", async () => {
            const newDebtSpReturned = await poolEnv.getMpHarness().newDebtSP();
            expect(newDebtSpReturned).to.equal(parseUnits("0"));
          });
          describe("AND GIVEN another 100 tokens are taken out", async () => {
            beforeEach(async () => {
              await poolEnv.borrowMoney("100", mockedMaxDebt);
            });
            describe("WHEN another 50 tokens are withdrawn", async () => {
              beforeEach(async () => {
                await poolEnv.withdrawMoney("50", mockedMaxDebt);
                mp = await poolEnv.mpHarness.maturityPool();
              });

              it("THEN the pool 'supplied' is 0", async () => {
                expect(mp.supplied).to.equal(parseUnits("0"));
              });
              it("THEN the newDebtSP that is returned is 50", async () => {
                const newDebtSpReturned = await poolEnv
                  .getMpHarness()
                  .newDebtSP();
                expect(newDebtSpReturned).to.equal(parseUnits("50"));
              });
            });
            describe("AND WHEN more tokens are taken out than the max sp debt", async () => {
              let tx: any;
              beforeEach(async () => {
                tx = poolEnv.withdrawMoney("50", "49");
              });
              it("THEN it reverts with error INSUFFICIENT_PROTOCOL_LIQUIDITY", async () => {
                await expect(tx).to.be.revertedWith(
                  errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
                );
              });
            });
          });
          describe("AND WHEN another 50 tokens are withdrawn", async () => {
            beforeEach(async () => {
              await poolEnv.withdrawMoney("50", mockedMaxDebt);
              mp = await poolEnv.mpHarness.maturityPool();
            });

            it("THEN the pool 'supplied' is 0", async () => {
              expect(mp.supplied).to.equal(parseUnits("0"));
            });
            it("THEN the newDebtSP that is returned is 0", async () => {
              const newDebtSpReturned = await poolEnv
                .getMpHarness()
                .newDebtSP();
              expect(newDebtSpReturned).to.equal(parseUnits("0"));
            });
          });
        });
      });
    });

    describe("scaleProportionally", async () => {
      describe("GIVEN a 100 scaledDebtPrincipal AND a 100 scaledDebtFee", async () => {
        describe("WHEN 50 is proportionally scaled", async () => {
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
          describe("AND WHEN another 5 is proportionally scaled", async () => {
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
      describe("GIVEN a 100 scaledDebtPrincipal AND a 0 scaledDebtFee", async () => {
        describe("WHEN 50 is proportionally scaled", async () => {
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
      describe("GIVEN a 0 scaledDebtPrincipal AND a 100 scaledDebtFee", async () => {
        describe("WHEN 50 is proportionally scaled", async () => {
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
      describe("GIVEN a 0 scaledDebtPrincipal AND a 100 scaledDebtFee", async () => {
        describe("WHEN 100 is proportionally scaled", async () => {
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

    describe("reduceProportionally", async () => {
      describe("GIVEN a 100 scaledDebtPrincipal AND a 100 scaledDebtFee", async () => {
        describe("WHEN 50 is proportionally reduced", async () => {
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
          describe("AND WHEN another 150 is proportionally reduced", async () => {
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
      describe("GIVEN a 100 scaledDebtPrincipal AND a 0 scaledDebtFee", async () => {
        describe("WHEN 50 is proportionally reduced", async () => {
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
      describe("GIVEN a 0 scaledDebtPrincipal AND a 100 scaledDebtFee", async () => {
        describe("WHEN 100 is proportionally reduced", async () => {
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

    describe("distributeAccordingly", async () => {
      let lastEarningsSP: BigNumber;
      let lastEarningsTreasury: BigNumber;
      describe("GIVEN 100 earnings, 1000 supplySP and 800 amountFunded", async () => {
        beforeEach(async () => {
          await poolEnv.distributeAccordingly("100", "1000", "800");
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

      describe("GIVEN 100 earnings, 400 supplySP and 800 amountFunded", async () => {
        beforeEach(async () => {
          await poolEnv.distributeAccordingly("100", "400", "800");
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

      describe("GIVEN 100 earnings, 0 supplySP and 800 amountFunded", async () => {
        beforeEach(async () => {
          await poolEnv.distributeAccordingly("100", "0", "800");
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

      describe("GIVEN 0 earnings, 0 supplySP and 800 amountFunded", async () => {
        beforeEach(async () => {
          await poolEnv.distributeAccordingly("0", "0", "800");
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
