import { expect } from "chai";
import { parseUnits } from "ethers/lib/utils";
import { errorGeneric, ProtocolError } from "./exactlyUtils";
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

    describe("addMoney & takeMoney", async () => {
      describe("WHEN 100 tokens are deposited", async () => {
        beforeEach(async () => {
          await poolEnv.addMoney("100");
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
            await poolEnv.takeMoney("80", mockedMaxDebt);
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
              await poolEnv.takeMoney("20", mockedMaxDebt);
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
                tx = poolEnv.takeMoney("5000", "1000");
              });
              it("THEN it reverts with error INSUFFICIENT_PROTOCOL_LIQUIDITY", async () => {
                await expect(tx).to.be.revertedWith(
                  errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
                );
              });
            });
            describe("AND WHEN 50 tokens are taken out", async () => {
              beforeEach(async () => {
                await poolEnv.takeMoney("50", mockedMaxDebt);
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

    describe("repayMoney", async () => {
      describe("WHEN 100 tokens are taken out", async () => {
        beforeEach(async () => {
          await poolEnv.takeMoney("100", mockedMaxDebt);
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
          await poolEnv.addMoney("100");
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
              await poolEnv.takeMoney("100", mockedMaxDebt);
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
            describe("WHEN another 50 tokens are withdrawn for 45 tokens", async () => {
              beforeEach(async () => {
                await poolEnv.withdrawMoneyAsym("50", "45", mockedMaxDebt);
                mp = await poolEnv.mpHarness.maturityPool();
              });

              it("THEN the pool 'supplied' is 0", async () => {
                expect(mp.supplied).to.equal(parseUnits("0"));
              });
              it("THEN the newDebtSP that is returned is 45", async () => {
                const newDebtSpReturned = await poolEnv
                  .getMpHarness()
                  .newDebtSP();
                expect(newDebtSpReturned).to.equal(parseUnits("45"));
              });
              it("THEN the mp.suppliedSP is 95", async () => {
                expect(mp.suppliedSP).to.equal(parseUnits("95"));
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

    describe("reduceFees", async () => {
      describe("GIVEN a 100 scaledDebtFee, WHEN 50 fees are reduced", async () => {
        beforeEach(async () => {
          await poolEnv.reduceFee("100", "50");
          scaledDebt = await poolEnv.getMpHarness().scaledDebt();
        });

        it("THEN the scaledDebtFee is 50", async () => {
          expect(scaledDebt.fee).to.equal(parseUnits("50"));
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
  });
});
