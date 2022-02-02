import { expect } from "chai";
import { parseUnits } from "ethers/lib/utils";
import { ethers } from "hardhat";
import { ExaTime } from "./exactlyUtils";
import { PoolEnv } from "./poolEnv";
import { DefaultEnv } from "./defaultEnv";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { BigNumber } from "ethers";

describe("Pool Management Library", () => {
  const exaTime = new ExaTime();

  let poolEnv: PoolEnv;
  let defaultEnv: DefaultEnv;
  let snapshot: any;
  let owner: SignerWithAddress;
  let juana: SignerWithAddress;
  let walter: SignerWithAddress;
  let cindy: SignerWithAddress;
  let fakeMultisig: SignerWithAddress;

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  describe("GIVEN a clean maturity pool", () => {
    beforeEach(async () => {
      poolEnv = await PoolEnv.create();
    });

    describe("WHEN 100 token are deposited to maturity 10 days", async () => {
      let mp: any;
      beforeEach(async () => {
        await poolEnv.addMoney(exaTime.day(10), "100");
        mp = await poolEnv.mpHarness.maturityPool();
      });

      it("THEN the pool 'borrowed' is 0", async () => {
        expect(mp.borrowed).to.equal(parseUnits("0"));
      });

      it("THEN the pool 'supplied' is 100", async () => {
        expect(mp.supplied).to.equal(parseUnits("100"));
      });

      it("THEN the pool 'unassignedEarnings' are 0", async () => {
        expect(mp.unassignedEarnings).to.equal(parseUnits("0"));
      });

      it("THEN the pool 'earningsSP' are 0", async () => {
        expect(mp.earningsSP).to.equal(parseUnits("0"));
      });

      it("THEN the smart pool total debt is 0", async () => {
        let smartPoolTotalDebt = await poolEnv.mpHarness.smartPoolTotalDebt();
        expect(smartPoolTotalDebt).to.equal(parseUnits("0"));
      });

      it("THEN the pool 'lastFee' is 0", async () => {
        expect(await poolEnv.mpHarness.lastFee()).to.equal(parseUnits("0"));
      });

      describe("AND WHEN 80 token are taken out, with 10 of fees to be paid", async () => {
        let mp: any;
        beforeEach(async () => {
          await poolEnv.takeMoneyAndAddFee(exaTime.day(10), "80", "10");
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'borrowed' is 80", async () => {
          expect(mp.borrowed).to.equal(parseUnits("80"));
        });

        it("THEN the pool 'supplied' is 100", async () => {
          expect(mp.supplied).to.equal(parseUnits("100"));
        });

        it("THEN the pool 'unassignedEarnings' are 10", async () => {
          expect(mp.unassignedEarnings).to.equal(parseUnits("10"));
        });

        it("THEN the pool 'earningsSP' are 0", async () => {
          expect(mp.earningsSP).to.equal(parseUnits("0"));
        });

        it("THEN the smart pool total debt is 0", async () => {
          let smartPoolTotalDebt = await poolEnv.mpHarness.smartPoolTotalDebt();
          expect(smartPoolTotalDebt).to.equal(parseUnits("0"));
        });

        describe("AND WHEN 70 token are taken out, with 8 of fees to be paid", async () => {
          let mp: any;
          beforeEach(async () => {
            await poolEnv.takeMoneyAndAddFee(exaTime.day(10), "70", "8");
            mp = await poolEnv.mpHarness.maturityPool();
          });

          it("THEN the pool 'borrowed' is 150", async () => {
            expect(mp.borrowed).to.equal(parseUnits("150"));
          });

          it("THEN the pool 'supplied' is 100", async () => {
            expect(mp.supplied).to.equal(parseUnits("100"));
          });

          it("THEN the pool 'unassignedEarnings' at maturity are close to 18", async () => {
            expect(mp.unassignedEarnings).to.closeTo(
              parseUnits("18"),
              parseUnits("0.0001").toNumber()
            );
          });

          it("THEN the pool 'earningsSP' are close to 0", async () => {
            expect(mp.earningsSP).to.closeTo(
              parseUnits("0"),
              parseUnits("0.0001").toNumber()
            );
          });

          it("THEN the smart pool total debt is 50", async () => {
            let smartPoolTotalDebt =
              await poolEnv.mpHarness.smartPoolTotalDebt();
            expect(smartPoolTotalDebt).to.equal(parseUnits("50"));
          });

          describe("AND WHEN we reach maturity and go over 1 day", async () => {
            let mp: any;
            beforeEach(async () => {
              await poolEnv.moveInTime(exaTime.day(11));
              await poolEnv.accrueEarningsToSP(exaTime.nextPoolID());
              mp = await poolEnv.mpHarness.maturityPool();
            });

            it("THEN the pool 'unassignedEarnings' at maturity are 0", async () => {
              expect(mp.unassignedEarnings).to.equal(parseUnits("0"));
            });

            it("THEN the pool 'earningsSP' are 18", async () => {
              expect(mp.earningsSP).to.equal(parseUnits("18"));
            });

            it("THEN the 'lastAccrue' is equal to the maturity date", async () => {
              expect(mp.lastAccrue).to.equal(exaTime.nextPoolID());
            });

            describe("AND WHEN two more days goes by, nothing changes", async () => {
              let mp: any;
              beforeEach(async () => {
                await poolEnv.moveInTime(exaTime.day(12));
                await poolEnv.accrueEarningsToSP(exaTime.nextPoolID());
                mp = await poolEnv.mpHarness.maturityPool();
              });

              it("THEN the pool 'earnings' at maturity are 0", async () => {
                expect(mp.unassignedEarnings).to.equal(parseUnits("0"));
              });

              it("THEN the pool 'earningsSP' are 18", async () => {
                expect(mp.earningsSP).to.equal(parseUnits("18"));
              });

              it("THEN the 'lastAccrue' is equal to the maturity date", async () => {
                expect(mp.lastAccrue).to.equal(exaTime.nextPoolID());
              });
            });
          });
        });
      });
    });

    describe("WHEN 100 token are taken out, with 10 of fees to be paid", async () => {
      let mp: any;
      beforeEach(async () => {
        await poolEnv.takeMoneyAndAddFee(exaTime.nextPoolID(), "100", "10");
        mp = await poolEnv.mpHarness.maturityPool();
      });

      it("THEN the pool 'borrowed' is 100", async () => {
        expect(mp.borrowed).to.equal(parseUnits("100"));
      });

      it("THEN the pool 'unassignedEarnings' are 10", async () => {
        expect(mp.unassignedEarnings).to.equal(parseUnits("10"));
      });

      it("THEN the smart pool total debt is 100", async () => {
        let smartPoolTotalDebt = await poolEnv.mpHarness.smartPoolTotalDebt();
        expect(smartPoolTotalDebt).to.equal(parseUnits("100"));
      });
    });

    describe("WHEN 100 tokens are borrowed, 10 tokens are fees, and 100 token are deposited (same deposited)", async () => {
      let mp: any;
      beforeEach(async () => {
        await poolEnv.takeMoneyAndAddFee(exaTime.day(10), "100", "10");
        await poolEnv.addMoney(exaTime.day(10), "100");
        mp = await poolEnv.mpHarness.maturityPool();
      });

      it("THEN the pool 'borrowed' is 100", async () => {
        expect(mp.borrowed).to.equal(parseUnits("100"));
      });

      it("THEN the pool 'earningsMP' is 5", async () => {
        expect(mp.earningsMP).to.be.closeTo(
          parseUnits("5"),
          parseUnits("0.0001").toNumber()
        );
      });

      it("THEN the pool 'unassignedEarnings' is close to 5", async () => {
        expect(mp.unassignedEarnings).to.closeTo(
          parseUnits("5"),
          parseUnits("0.0001").toNumber()
        );
      });

      it("THEN the pool 'lastFee' is close to 5", async () => {
        expect(await poolEnv.mpHarness.lastFee()).to.closeTo(
          parseUnits("5"),
          parseUnits("0.0001").toNumber()
        );
      });

      it("THEN the pool 'earningsSP' are close to 0", async () => {
        expect(mp.earningsSP).to.closeTo(
          parseUnits("0"),
          parseUnits("0.0001").toNumber()
        );
      });

      it("THEN the pool 'supplied' is 100 (100 principal)", async () => {
        // supply should consider the newly taken fee
        expect(mp.supplied).to.equal(parseUnits("100"));
      });

      it("THEN the smart pool total debt is 100", async () => {
        let smartPoolTotalDebt = await poolEnv.mpHarness.smartPoolTotalDebt();
        expect(smartPoolTotalDebt).to.equal(parseUnits("100"));
      });

      it("THEN the smart pool supply on maturity pool is 100", async () => {
        expect(mp.suppliedSP).to.equal(parseUnits("100"));
      });
    });

    describe("WHEN 100 tokens are borrowed, 15 tokens are fees, and 50 token are deposited (less deposited)", async () => {
      let mp: any;
      beforeEach(async () => {
        await poolEnv.takeMoneyAndAddFee(exaTime.day(10), "100", "15");
        await poolEnv.addMoney(exaTime.day(10), "50");
        mp = await poolEnv.mpHarness.maturityPool();
      });

      it("THEN the pool 'borrowed' is 100", async () => {
        expect(mp.borrowed).to.equal(parseUnits("100"));
      });

      it("THEN the pool 'earningsMP' is 5", async () => {
        expect(mp.earningsMP).to.be.closeTo(
          parseUnits("5"),
          parseUnits("0.0001").toNumber()
        );
      });

      it("THEN the pool 'unassignedEarnings' are close to 10", async () => {
        expect(mp.unassignedEarnings).to.closeTo(
          parseUnits("10"),
          parseUnits("0.0001").toNumber()
        );
      });

      it("THEN the pool 'lastFee' is close to 5", async () => {
        expect(await poolEnv.mpHarness.lastFee()).to.closeTo(
          parseUnits("5"),
          parseUnits("0.0001").toNumber()
        );
      });

      it("THEN the pool 'earningsSP' are close to 0", async () => {
        expect(mp.earningsSP).to.closeTo(
          parseUnits("0"),
          parseUnits("0.0001").toNumber()
        );
      });

      it("THEN the pool 'supplied' is 50", async () => {
        // supply should consider the newly taken fee
        expect(mp.supplied).to.equal(parseUnits("50"));
      });

      it("THEN the smart pool total debt is 100", async () => {
        let smartPoolTotalDebt = await poolEnv.mpHarness.smartPoolTotalDebt();
        expect(smartPoolTotalDebt).to.equal(parseUnits("100"));
      });

      it("THEN the smart pool 'supplied' to maturity pool is 100", async () => {
        expect(mp.suppliedSP).to.equal(parseUnits("100"));
      });
    });

    describe("WHEN 100 tokens are borrowed, 60 tokens are fees, and 500 token are deposited (more deposit)", async () => {
      let mp: any;
      beforeEach(async () => {
        await poolEnv.takeMoneyAndAddFee(exaTime.day(10), "100", "60");
        await poolEnv.addMoney(exaTime.day(10), "500");
        mp = await poolEnv.mpHarness.maturityPool();
      });

      it("THEN the pool 'borrowed' is 100", async () => {
        expect(mp.borrowed).to.equal(parseUnits("100"));
      });

      it("THEN the pool 'unassignedEarnings' are close to 10", async () => {
        expect(mp.unassignedEarnings).to.closeTo(
          parseUnits("10"),
          parseUnits("0.0001").toNumber()
        );
      });

      it("THEN the pool 'earningsMP' is 50", async () => {
        expect(mp.earningsMP).to.be.closeTo(
          parseUnits("50"),
          parseUnits("0.0001").toNumber()
        );
      });

      it("THEN the pool 'lastFee' is close to 50", async () => {
        expect(await poolEnv.mpHarness.lastFee()).to.closeTo(
          parseUnits("50"),
          parseUnits("0.0001").toNumber()
        );
      });

      it("THEN the pool 'earningsSP' are close to 0", async () => {
        expect(mp.earningsSP).to.closeTo(
          parseUnits("0"),
          parseUnits("0.0001").toNumber()
        );
      });

      it("THEN the pool 'supplied' is 500", async () => {
        expect(mp.supplied).to.equal(parseUnits("500"));
      });

      it("THEN the smart pool total debt is 100", async () => {
        let smartPoolTotalDebt = await poolEnv.mpHarness.smartPoolTotalDebt();
        expect(smartPoolTotalDebt).to.equal(parseUnits("100"));
      });

      it("THEN the smart pool 'supplied' on maturity pool is 100", async () => {
        expect(mp.suppliedSP).to.equal(parseUnits("100"));
      });
    });
  });

  describe("GIVEN a loan of 100 that will pay 10 in fees in 10 days", () => {
    let fakeMaturityPool = exaTime.day(10);
    beforeEach(async () => {
      poolEnv = await PoolEnv.create();
      await poolEnv.takeMoneyAndAddFee(fakeMaturityPool, "100", "10");
    });

    describe("WHEN 2 days go by and another user deposits 100 to the same Maturity Pool", async () => {
      let mp: any;
      beforeEach(async () => {
        await poolEnv.moveInTime(exaTime.day(2));
        await poolEnv.addMoney(fakeMaturityPool, "100");
        mp = await poolEnv.mpHarness.maturityPool();
      });

      it("THEN the pool 'earningsSP' is around 2", async () => {
        expect(mp.earningsSP).to.be.lt(parseUnits("2"));
        expect(mp.earningsSP).to.be.gt(parseUnits("1.95"));
      });

      it("THEN the pool 'earningsMP' is 4", async () => {
        expect(mp.earningsMP).to.be.lt(parseUnits("4.1"));
        expect(mp.earningsMP).to.be.gt(parseUnits("3.9"));
      });

      it("THEN the pool 'unassignedEarnings' are around 4", async () => {
        expect(mp.unassignedEarnings).to.be.lt(parseUnits("4.05"));
        expect(mp.unassignedEarnings).to.be.gt(parseUnits("4"));
      });

      it("THEN the pool 'lastFee' is around 4", async () => {
        expect(await poolEnv.mpHarness.lastFee()).to.be.lt(parseUnits("4.05"));
        expect(await poolEnv.mpHarness.lastFee()).to.be.gt(parseUnits("4"));
      });

      describe("AND GIVEN that 4 more days go by and more fees are generated ", () => {
        let mp: any;
        beforeEach(async () => {
          await poolEnv.moveInTime(exaTime.day(6));
          await poolEnv.takeMoneyAndAddFee(fakeMaturityPool, "100", "10");
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'earningsSP' is 4", async () => {
          expect(mp.earningsSP).to.be.lt(parseUnits("4"));
          expect(mp.earningsSP).to.be.gt(parseUnits("3.95"));
        });

        it("THEN the pool 'unassignedEarnings' are 12", async () => {
          expect(mp.unassignedEarnings).to.closeTo(
            parseUnits("12"),
            parseUnits("0.009").toNumber()
          );
        });
      });

      describe("AND GIVEN that 4 more days go by and someone deposits 200", () => {
        let mp: any;
        beforeEach(async () => {
          await poolEnv.moveInTime(exaTime.day(6));
          await poolEnv.addMoney(fakeMaturityPool, "200");
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'earningsSP' is around 4", async () => {
          expect(mp.earningsSP).to.be.lt(parseUnits("4"));
          expect(mp.earningsSP).to.be.gt(parseUnits("3.95"));
        });

        it("THEN the pool 'unassignedEarnings' are around 0.666", async () => {
          expect(mp.unassignedEarnings).to.closeTo(
            parseUnits("0.666"),
            parseUnits("0.009").toNumber()
          );
        });

        it("THEN the pool 'lastFee' is around 1.3333", async () => {
          expect(await poolEnv.mpHarness.lastFee()).to.closeTo(
            parseUnits("1.333"),
            parseUnits("0.009").toNumber()
          );
        });

        it("THEN the pool 'earningsMP' is 5.3333", async () => {
          expect(mp.earningsMP).to.be.lt(parseUnits("5.4"));
          expect(mp.earningsMP).to.be.gt(parseUnits("5.3"));
        });

        describe("AND GIVEN that maturity arrives and someone repays 100 (the MP is borrowing 100 from the SP)", () => {
          let mp: any;
          beforeEach(async () => {
            await poolEnv.moveInTime(exaTime.day(10));
            await poolEnv.repay(fakeMaturityPool, "100");
            mp = await poolEnv.mpHarness.maturityPool();
          });

          it("THEN the pool 'earningsSP' is around 4.666", async () => {
            expect(mp.earningsSP).to.be.lt(parseUnits("4.7"));
            expect(mp.earningsSP).to.be.gt(parseUnits("4.6"));
          });

          it("THEN the pool 'unassignedEarnings' at maturity are 0", async () => {
            expect(mp.unassignedEarnings).to.eq(0);
          });

          it("THEN the pool 'lastEarningsSP' is 0 (repayment didn't cover earnings)", async () => {
            expect(await poolEnv.mpHarness.lastEarningsSP()).to.eq(0);
          });

          it("THEN the pool 'earningsMP' is repaid (=0)", async () => {
            expect(mp.earningsMP).to.be.eq(0);
          });

          it("THEN the pool still is owed the MP supplier fees ('suppliedSP'=10 total - 4.6666 given to SP)", async () => {
            expect(mp.suppliedSP).to.be.lt(parseUnits("5.35"));
            expect(mp.suppliedSP).to.be.gt(parseUnits("5.33"));
          });

          it("THEN the pool have deposits to be repaid for 300", async () => {
            expect(mp.supplied).to.eq(parseUnits("300"));
          });

          describe("AND GIVEN that someone repays again for 30", () => {
            let mp: any;
            beforeEach(async () => {
              await poolEnv.repay(fakeMaturityPool, "30");
              mp = await poolEnv.mpHarness.maturityPool();
            });

            it("THEN the pool 'earningsSP' is 0 (have been repaid)", async () => {
              expect(mp.earningsSP).to.eq(0);
            });

            it("THEN the pool 'unassignedEarnings' at maturity are 0", async () => {
              expect(mp.unassignedEarnings).to.eq(0);
            });

            it("THEN the pool 'lastEarningsSP' is around 4.6666", async () => {
              // 30 repay can be a repayment with penalties. In this case, since
              // all the other debt has been repaid, it  covers all the spread
              // of the earnings to be paid
              expect(await poolEnv.mpHarness.lastEarningsSP()).to.be.lt(
                parseUnits("4.7")
              );
              expect(await poolEnv.mpHarness.lastEarningsSP()).to.be.gt(
                parseUnits("4.6")
              );
            });

            it("THEN the pool 'lastExtrasSP' is 20", async () => {
              // 30 repay can be a repayment with penalties. In this case, since
              // all the other debt has been repaid, all the interests have been covered (10 = 4.6 for earninings SP and rest for earningsMP)
              // then all the rest goes to the SP and not shared with anyone
              expect(await poolEnv.mpHarness.lastExtrasSP()).to.be.eq(
                parseUnits("30").sub(parseUnits("10"))
              );
            });

            it("THEN the pool 'suppliedSP' is 0 (debt has been repaid)", async () => {
              expect(mp.suppliedSP).to.eq(parseUnits("0"));
            });

            it("THEN the pool has all the previous deposits intact (300 principal)", async () => {
              expect(mp.supplied).to.eq(parseUnits("300"));
            });

            describe("AND GIVEN that someone repays again for 40", () => {
              let mp: any;
              beforeEach(async () => {
                await poolEnv.repay(fakeMaturityPool, "40");
                mp = await poolEnv.mpHarness.maturityPool();
              });

              it("THEN the pool 'earningsSP' is 0", async () => {
                expect(mp.earningsSP).to.eq(0);
              });

              it("THEN the pool 'unassignedEarnings' at maturity are 0", async () => {
                expect(mp.unassignedEarnings).to.eq(0);
              });

              it("THEN the pool 'lastExtrasSP' is 40", async () => {
                expect(await poolEnv.mpHarness.lastExtrasSP()).to.eq(
                  parseUnits("40") // SP receives it all
                );
              });

              it("THEN the pool 'suppliedSP' is 0", async () => {
                expect(mp.suppliedSP).to.eq(parseUnits("0"));
              });

              it("THEN the pool has all the previous deposits intact (300 principal)", async () => {
                expect(mp.supplied).to.eq(parseUnits("300"));
              });

              it("THEN 'lastAccrue' is the day 10", async () => {
                expect(mp.lastAccrue).to.eq(exaTime.day(10));
              });
            });

            describe("AND GIVEN that someone withdraws 300", () => {
              let mp: any;
              beforeEach(async () => {
                await poolEnv.takeMoneyAndAddFee(fakeMaturityPool, "300", "0");
                mp = await poolEnv.mpHarness.maturityPool();
              });

              it("THEN the pool 'supplied' - 'borrowed' equals 0", async () => {
                expect(mp.earningsSP).to.eq(0);
                expect(mp.supplied.sub(mp.borrowed)).to.eq(0);
                expect(mp.suppliedSP).to.eq(0);
              });
            });
          });
        });

        describe("AND GIVEN that maturity arrives and someone repays 90 (the MP is borrowing 100 from the SP)", () => {
          let mp: any;
          beforeEach(async () => {
            await poolEnv.moveInTime(exaTime.day(10));
            await poolEnv.repay(fakeMaturityPool, "90");
            mp = await poolEnv.mpHarness.maturityPool();
          });

          it("THEN the pool 'earningsSP' is around 4.666", async () => {
            expect(mp.earningsSP).to.be.lt(parseUnits("4.7"));
            expect(mp.earningsSP).to.be.gt(parseUnits("4.6"));
          });

          it("THEN the pool 'unassignedEarnings' at maturity are 0", async () => {
            expect(mp.unassignedEarnings).to.eq(0);
          });

          it("THEN the pool 'lastEarningsSP' is 0 (repayment didn't cover earnings)", async () => {
            expect(await poolEnv.mpHarness.lastEarningsSP()).to.eq(0);
          });

          it("THEN the pool owes 15.333 to the smart pool ('suppliedSP'=10 + original 5.3333 MP fees)", async () => {
            expect(mp.suppliedSP).to.be.lt(parseUnits("15.35"));
            expect(mp.suppliedSP).to.be.gt(parseUnits("15.33"));
          });

          it("THEN the pool have deposits to be repaid for 300", async () => {
            expect(mp.supplied).to.eq(parseUnits("300"));
          });

          describe("AND GIVEN that someone repays again for 30", () => {
            let mp: any;
            beforeEach(async () => {
              await poolEnv.repay(fakeMaturityPool, "30");
              mp = await poolEnv.mpHarness.maturityPool();
            });

            it("THEN the pool 'earningsSP' is 0 (have been repaid)", async () => {
              expect(mp.earningsSP).to.eq(0);
            });

            it("THEN the pool 'unassignedEarnings' at maturity are 0", async () => {
              expect(mp.unassignedEarnings).to.eq(0);
            });

            it("THEN the pool 'lastEarningsSP' is around 4.6666", async () => {
              // 30 repay can be a repayment with penalties. In this case, 10 went for the remaining debt
              // 4.66666 as earnings and .... (see next test)
              expect(await poolEnv.mpHarness.lastEarningsSP()).to.be.lt(
                parseUnits("4.7")
              );
              expect(await poolEnv.mpHarness.lastEarningsSP()).to.be.gt(
                parseUnits("4.6")
              );
            });

            it("THEN the pool 'lastExtrasSP' is 10", async () => {
              // ... and the extras is 20 - (4.66666 SP fees + 5.3333 MP fees) = 10
              expect(await poolEnv.mpHarness.lastExtrasSP()).to.be.eq(
                parseUnits("20").sub(parseUnits("10"))
              );
            });

            it("THEN the pool 'suppliedSP' is 0 (debt has been repaid)", async () => {
              expect(mp.suppliedSP).to.eq(parseUnits("0"));
            });

            it("THEN the pool has all the previous deposits intact (300 principal)", async () => {
              expect(mp.supplied).to.eq(parseUnits("300"));
            });
          });
        });
      });
    });
  });

  describe("GIVEN that Walter deposits 60000 DAI in the Smart Pool AND 6% penalty rate", () => {
    beforeEach(async () => {
      defaultEnv = await DefaultEnv.create({});
      [, juana, cindy, walter] = await ethers.getSigners();
      await defaultEnv.transfer("ETH", juana, "200");
      await defaultEnv.transfer("DAI", juana, "200");
      await defaultEnv.transfer("DAI", cindy, "3000");
      await defaultEnv.transfer("DAI", walter, "60000");
      await defaultEnv
        .getInterestRateModel()
        .setPenaltyRate(parseUnits("0.06"));

      defaultEnv.switchWallet(walter);
      await defaultEnv.depositSP("DAI", "60000");
      defaultEnv.switchWallet(juana);
      await defaultEnv.depositSP("ETH", "100");
      await defaultEnv.enterMarkets(["ETH"]);
    });

    describe("WHEN Juana borrows 4000 DAI in the next maturity pool", () => {
      beforeEach(async () => {
        defaultEnv.switchWallet(juana);
        await defaultEnv.borrowMP("DAI", exaTime.nextPoolID(), "4000");
      });

      it("THEN the debt of the smart pool is 4000", async () => {
        const mp = await defaultEnv.maturityPool("DAI", exaTime.nextPoolID());
        const borrowSP = await defaultEnv
          .getPoolAccounting("DAI")
          .smartPoolBorrowed();
        expect(mp.suppliedSP).to.equal(parseUnits("4000"));
        expect(borrowSP).to.equal(parseUnits("4000"));
      });

      describe("AND WHEN Cindy deposits 3000", () => {
        beforeEach(async () => {
          defaultEnv.switchWallet(cindy);
          await defaultEnv.depositMP("DAI", exaTime.nextPoolID(), "3000");
        });

        describe("AND WHEN Juana repays 4000 at maturity", () => {
          beforeEach(async () => {
            defaultEnv.switchWallet(juana);
            await defaultEnv.moveInTime(exaTime.nextPoolID());
            await defaultEnv.repayMP("DAI", exaTime.nextPoolID(), "4000");
          });

          it("THEN the debt of the smart pool is back to 0", async () => {
            const mp = await defaultEnv.maturityPool(
              "DAI",
              exaTime.nextPoolID()
            );
            const borrowSP = await defaultEnv
              .getPoolAccounting("DAI")
              .smartPoolBorrowed();
            expect(mp.suppliedSP).to.equal(0);
            expect(borrowSP).to.equal(0);
          });
        });

        describe("AND Juana repays 2000 at maturity", () => {
          beforeEach(async () => {
            defaultEnv.switchWallet(juana);
            await defaultEnv.moveInTime(exaTime.nextPoolID());
            await defaultEnv.repayMP("DAI", exaTime.nextPoolID(), "2000");
          });

          it("THEN the debt of the smart pool is 2000", async () => {
            const mp = await defaultEnv.maturityPool(
              "DAI",
              exaTime.nextPoolID()
            );
            const borrowSP = await defaultEnv
              .getPoolAccounting("DAI")
              .smartPoolBorrowed();
            expect(mp.suppliedSP).to.equal(parseUnits("2000"));
            expect(borrowSP).to.equal(parseUnits("2000"));
          });

          describe("AND Juana repays another 2000 at maturity", () => {
            beforeEach(async () => {
              defaultEnv.switchWallet(juana);
              await defaultEnv.repayMP("DAI", exaTime.nextPoolID(), "2000");
            });

            it("THEN the debt of the smart pool is 0", async () => {
              const mp = await defaultEnv.maturityPool(
                "DAI",
                exaTime.nextPoolID()
              );
              expect(mp.suppliedSP).to.equal(0);
            });

            describe("AND Cindy withdraws her 3000 at maturity", () => {
              let mp: any;
              beforeEach(async () => {
                defaultEnv.switchWallet(cindy);
                await defaultEnv.withdrawMP(
                  "DAI",
                  exaTime.nextPoolID(),
                  "3000"
                );
                mp = await defaultEnv.maturityPool("DAI", exaTime.nextPoolID());
              });

              it("THEN the Maturity Pool is even", async () => {
                expect(mp.borrowed - mp.supplied).to.equal(0);
              });

              it("THEN the debt of the smart pool is 0", async () => {
                expect(mp.suppliedSP).to.equal(0);
              });
            });
          });
        });
      });
    });

    describe("WHEN Cindy deposits 3000", () => {
      beforeEach(async () => {
        defaultEnv.switchWallet(cindy);
        await defaultEnv.depositMP("DAI", exaTime.nextPoolID(), "3000");
      });

      describe("AND Juana borrows 4000 at maturity", () => {
        beforeEach(async () => {
          defaultEnv.switchWallet(juana);
          await defaultEnv.borrowMP("DAI", exaTime.nextPoolID(), "4000");
        });

        it("THEN the debt of the smart pool is to 1000", async () => {
          const mp = await defaultEnv.maturityPool("DAI", exaTime.nextPoolID());
          expect(mp.suppliedSP).to.equal(parseUnits("1000"));
        });

        describe("AND Cindy withdraws 3000 at maturity", () => {
          beforeEach(async () => {
            defaultEnv.switchWallet(cindy);
            await defaultEnv.moveInTime(exaTime.nextPoolID());
            await defaultEnv.withdrawMP("DAI", exaTime.nextPoolID(), "3000");
          });

          it("THEN the debt of the smart pool is to 4000", async () => {
            const mp = await defaultEnv.maturityPool(
              "DAI",
              exaTime.nextPoolID()
            );
            expect(mp.suppliedSP).to.equal(parseUnits("4000"));
          });
        });

        describe("AND Juana repays 4000 at maturity", () => {
          beforeEach(async () => {
            defaultEnv.switchWallet(juana);
            await defaultEnv.moveInTime(exaTime.nextPoolID());
            await defaultEnv.repayMP("DAI", exaTime.nextPoolID(), "4000");
          });

          it("THEN the debt of the smart pool is back to 0", async () => {
            const mp = await defaultEnv.maturityPool(
              "DAI",
              exaTime.nextPoolID()
            );
            expect(mp.suppliedSP).to.equal(0);
          });
        });

        describe("AND Juana repays 3000 at maturity", () => {
          beforeEach(async () => {
            defaultEnv.switchWallet(juana);
            await defaultEnv.moveInTime(exaTime.nextPoolID());
            await defaultEnv.repayMP("DAI", exaTime.nextPoolID(), "3000");
          });

          it("THEN the debt of the smart pool is still 1000", async () => {
            const mp = await defaultEnv.maturityPool(
              "DAI",
              exaTime.nextPoolID()
            );
            expect(mp.suppliedSP).to.equal(parseUnits("1000"));
          });

          describe("AND Juana repays another 1000 one(1) day after maturity", () => {
            let tx: any;
            beforeEach(async () => {
              defaultEnv.switchWallet(juana);
              await defaultEnv.moveInTime(
                exaTime.nextPoolID() + exaTime.ONE_DAY
              );
              tx = defaultEnv.repayMP("DAI", exaTime.nextPoolID(), "1000");
            });

            it("THEN the debt of the smart pool is 0", async () => {
              await tx;
              const mp = await defaultEnv.maturityPool(
                "DAI",
                exaTime.nextPoolID()
              );
              expect(mp.suppliedSP).to.equal(0);
            });

            it("THEN Juana didn't get to cover the penalties", async () => {
              await expect(tx)
                .to.emit(defaultEnv.getEToken("DAI"), "EarningsAccrued")
                .withArgs(0);
            });

            describe("AND Juana repays another 60 one(1) day after maturity for penalties", () => {
              let tx2: any;
              let mp: any;
              beforeEach(async () => {
                await tx;
                defaultEnv.switchWallet(juana);
                tx2 = defaultEnv.repayMP("DAI", exaTime.nextPoolID(), "60");
                mp = await defaultEnv.maturityPool("DAI", exaTime.nextPoolID());
              });

              it("THEN the debt of the smart pool is 0", async () => {
                await tx2;
                expect(mp.suppliedSP).to.equal(0);
              });

              it("THEN Juana got to cover her penalties", async () => {
                await expect(tx2)
                  .to.emit(defaultEnv.getEToken("DAI"), "EarningsAccrued")
                  .withArgs(parseUnits("60"));
              });

              describe("AND Cindy withdraws her 3000 after maturity", () => {
                let mp: any;
                beforeEach(async () => {
                  await tx2;
                  defaultEnv.switchWallet(cindy);
                  await defaultEnv.withdrawMP(
                    "DAI",
                    exaTime.nextPoolID(),
                    "3000"
                  );
                  mp = await defaultEnv.maturityPool(
                    "DAI",
                    exaTime.nextPoolID()
                  );
                });

                it("THEN the Maturity Pool is even", async () => {
                  expect(mp.borrowed - mp.supplied).to.equal(0);
                });

                it("THEN the debt of the smart pool is 0", async () => {
                  expect(mp.suppliedSP).to.equal(0);
                });
              });
            });
          });
        });
      });
    });
  });

  describe("GIVEN that Walter deposits 60000 DAI in the Smart Pool AND 6% penalty rate AND 10% borrow rate AND 10% protocol share (for the period, not yearly)", () => {
    beforeEach(async () => {
      defaultEnv = await DefaultEnv.create({});
      [owner, juana, cindy, walter, fakeMultisig] = await ethers.getSigners();

      // Juana has ETH to put as collateral, and some DAIf
      // to pay back the interests of her loan
      await defaultEnv.transfer("ETH", juana, "200");
      await defaultEnv.transfer("DAI", juana, "400");
      // Cindy will deposit to the MP of DAI
      await defaultEnv.transfer("DAI", cindy, "3000");
      // Walter will be providing liquidity to the SP
      await defaultEnv.transfer("DAI", walter, "60000");
      await defaultEnv
        .getInterestRateModel()
        .setPenaltyRate(parseUnits("0.06"));
      await defaultEnv.getInterestRateModel().setBorrowRate(parseUnits("0.1"));
      await defaultEnv
        .getFixedLender("DAI")
        .setProtocolSpreadFee(parseUnits("0.1"));
      defaultEnv.switchWallet(walter);
      await defaultEnv.depositSP("DAI", "60000");

      // This is Juana's colateral
      defaultEnv.switchWallet(juana);
      await defaultEnv.depositSP("ETH", "100");
      await defaultEnv.enterMarkets(["ETH"]);
    });

    describe("WHEN Juana borrows 4000 DAI in the next maturity pool", () => {
      beforeEach(async () => {
        defaultEnv.switchWallet(juana);
        await defaultEnv.borrowMP("DAI", exaTime.nextPoolID(), "4000");
      });

      it("THEN the debt of the smart pool is 4000", async () => {
        const mp = await defaultEnv.maturityPool("DAI", exaTime.nextPoolID());
        const borrowSP = await defaultEnv
          .getPoolAccounting("DAI")
          .smartPoolBorrowed();
        expect(mp.suppliedSP).to.equal(parseUnits("4000"));
        expect(borrowSP).to.equal(parseUnits("4000"));
      });

      describe("AND WHEN Cindy deposits 3000", () => {
        beforeEach(async () => {
          defaultEnv.switchWallet(cindy);
          await defaultEnv.depositMP("DAI", exaTime.nextPoolID(), "3000");
        });

        it("THEN Cindy's fee is 400 * 3000 / 7000", async () => {
          defaultEnv.switchWallet(cindy);
          const supplied = await defaultEnv
            .getPoolAccounting("DAI")
            .mpUserSuppliedAmount(exaTime.nextPoolID(), cindy.address);

          let fee = parseUnits("400")
            .mul(parseUnits("3000"))
            .div(parseUnits("7000"));

          expect(supplied).to.be.lt(parseUnits("3000").add(fee));
          expect(supplied).to.be.gt(
            parseUnits("3000").add(fee).sub(parseUnits("0.05"))
          );
        });

        describe("AND WHEN Juana repays 4000 at maturity", () => {
          let mp: any;
          beforeEach(async () => {
            defaultEnv.switchWallet(juana);
            await defaultEnv.moveInTime(exaTime.nextPoolID());
            await defaultEnv.repayMP("DAI", exaTime.nextPoolID(), "4000");
            mp = await defaultEnv.maturityPool("DAI", exaTime.nextPoolID());
          });

          it("THEN the debt of the smart pool is around 171 (earningsMP were paid first)", async () => {
            const borrowSP = await defaultEnv
              .getPoolAccounting("DAI")
              .smartPoolBorrowed();
            expect(mp.suppliedSP).to.gt(parseUnits("171"));
            expect(mp.suppliedSP).to.lt(parseUnits("172"));
            expect(borrowSP).to.gt(parseUnits("171"));
            expect(borrowSP).to.lt(parseUnits("172"));
          });

          it("THEN 'earningsSP' are still there (400 - previous MP deposit fee)", async () => {
            let previousFeeGiven = parseUnits("400")
              .mul(parseUnits("3000"))
              .div(parseUnits("7000"));

            expect(mp.earningsSP).to.be.gt(
              parseUnits("400").sub(previousFeeGiven)
            );
            expect(mp.earningsSP).to.be.lt(
              parseUnits("400").sub(previousFeeGiven).add(parseUnits("0.5"))
            );
          });

          it("THEN she still owes 10% (400 DAI)", async () => {
            const [, owed] = await defaultEnv.accountSnapshot(
              "DAI",
              exaTime.nextPoolID()
            );
            expect(owed).to.equal(parseUnits("400"));
          });

          describe("AND Juana repays 400 at maturity for her fee", () => {
            let mp: any;
            beforeEach(async () => {
              defaultEnv.switchWallet(juana);
              await defaultEnv.repayMP("DAI", exaTime.nextPoolID(), "400");
              mp = await defaultEnv.maturityPool("DAI", exaTime.nextPoolID());
            });

            it("THEN 'earningsSP' are 0", async () => {
              expect(mp.earningsSP).to.equal(0);
            });

            it("THEN owes 0 to the pool", async () => {
              const [, owed] = await defaultEnv.accountSnapshot(
                "DAI",
                exaTime.nextPoolID()
              );
              expect(owed).to.equal(0);
            });
          });
        });
      });
    });

    describe("WHEN Cindy deposits 3000", () => {
      beforeEach(async () => {
        defaultEnv.switchWallet(cindy);
        await defaultEnv.depositMP("DAI", exaTime.nextPoolID(), "3000");
      });

      describe("AND Juana borrows 4000 at maturity", () => {
        beforeEach(async () => {
          defaultEnv.switchWallet(juana);
          await defaultEnv.borrowMP("DAI", exaTime.nextPoolID(), "4000");
        });

        it("THEN the debt of the smart pool is to 1000", async () => {
          const mp = await defaultEnv.maturityPool("DAI", exaTime.nextPoolID());
          expect(mp.suppliedSP).to.equal(parseUnits("1000"));
        });

        describe("AND Cindy withdraws 3000 at maturity", () => {
          beforeEach(async () => {
            defaultEnv.switchWallet(cindy);
            await defaultEnv.moveInTime(exaTime.nextPoolID());
            await defaultEnv.withdrawMP("DAI", exaTime.nextPoolID(), "3000");
          });

          it("THEN the debt of the smart pool is to 4000", async () => {
            const mp = await defaultEnv.maturityPool(
              "DAI",
              exaTime.nextPoolID()
            );
            expect(mp.suppliedSP).to.equal(parseUnits("4000"));
          });
        });

        describe("AND Juana repays 3000 at maturity", () => {
          beforeEach(async () => {
            defaultEnv.switchWallet(juana);
            await defaultEnv.moveInTime(exaTime.nextPoolID());
            await defaultEnv.repayMP("DAI", exaTime.nextPoolID(), "3000");
          });

          it("THEN the debt of the smart pool is still 1000", async () => {
            const mp = await defaultEnv.maturityPool(
              "DAI",
              exaTime.nextPoolID()
            );
            expect(mp.suppliedSP).to.equal(parseUnits("1000"));
          });

          describe("AND Juana repays another 1000 DAI one(1) day after maturity", () => {
            let tx: any;
            beforeEach(async () => {
              defaultEnv.switchWallet(juana);
              await defaultEnv.moveInTime(
                exaTime.nextPoolID() + exaTime.ONE_DAY
              );
              tx = defaultEnv.repayMP("DAI", exaTime.nextPoolID(), "1000");
            });

            it("THEN the debt of the smart pool is 0", async () => {
              await tx;
              const mp = await defaultEnv.maturityPool(
                "DAI",
                exaTime.nextPoolID()
              );
              expect(mp.suppliedSP).to.equal(0);
            });

            it("THEN Juana didn't get to cover the penalties", async () => {
              await expect(tx)
                .to.emit(defaultEnv.getEToken("DAI"), "EarningsAccrued")
                .withArgs(0);
            });

            it("THEN she still owes 6% of the 1400 remaining DAI for the penalties (484 DAI)", async () => {
              await tx;
              const [, owed] = await defaultEnv.accountSnapshot(
                "DAI",
                exaTime.nextPoolID()
              );
              expect(owed).to.equal(parseUnits("484"));
            });

            describe("AND Juana repays another 60 DAI one(1) day after maturity for penalties", () => {
              let tx2: any;
              let mp: any;
              beforeEach(async () => {
                await tx;
                defaultEnv.switchWallet(juana);
                tx2 = defaultEnv.repayMP("DAI", exaTime.nextPoolID(), "60");
                mp = await defaultEnv.maturityPool("DAI", exaTime.nextPoolID());
              });

              it("THEN the debt of the smart pool is 0", async () => {
                await tx2;
                expect(mp.suppliedSP).to.equal(0);
              });

              it("THEN Juana got to cover some of her penalties (60 - protocolfee = 54)", async () => {
                await expect(tx2)
                  .to.emit(defaultEnv.getEToken("DAI"), "EarningsAccrued")
                  .withArgs(parseUnits("54"));
              });

              it("THEN protocol earnings are 6 (10% out of 60)", async () => {
                await tx2;
                expect(await defaultEnv.treasury("DAI")).to.equal(
                  parseUnits("6")
                );
              });

              it("THEN 'earningsSP' are still there (400)", async () => {
                await tx2;
                expect(mp.earningsSP).to.equal(parseUnits("400"));
              });

              it("THEN she still owes 10% (400 DAI)", async () => {
                await tx2;
                const [, owed] = await defaultEnv.accountSnapshot(
                  "DAI",
                  exaTime.nextPoolID()
                );
                expect(owed).to.closeTo(
                  parseUnits("424"),
                  parseUnits("0.000001").toNumber()
                );
              });

              describe("AND admin withdraw the funds that were earned by the protocol", () => {
                let balancePre: BigNumber;
                let balancePost: BigNumber;
                beforeEach(async () => {
                  await tx2;
                  defaultEnv.switchWallet(owner);
                  balancePre = await defaultEnv
                    .getUnderlying("DAI")
                    .balanceOf(fakeMultisig.address);
                  await defaultEnv
                    .getFixedLender("DAI")
                    .withdrawFromTreasury(
                      fakeMultisig.address,
                      parseUnits("6")
                    );
                  balancePost = await defaultEnv
                    .getUnderlying("DAI")
                    .balanceOf(fakeMultisig.address);
                });

                it("THEN the fakeMultisig had 0 funds before", async () => {
                  expect(balancePre).to.equal(0);
                });

                it("THEN the fakeMultisig has 6 DAI after", async () => {
                  expect(balancePost).to.equal(parseUnits("6"));
                });

                it("THEN protocol earnings are 0 (they were withdrawn)", async () => {
                  await tx2;
                  expect(await defaultEnv.treasury("DAI")).to.equal(0);
                });
              });

              describe("AND Cindy withdraws her 3000 after maturity", () => {
                let mp: any;
                beforeEach(async () => {
                  await tx2;
                  defaultEnv.switchWallet(cindy);
                  await defaultEnv.withdrawMP(
                    "DAI",
                    exaTime.nextPoolID(),
                    "3000"
                  );
                  mp = await defaultEnv.maturityPool(
                    "DAI",
                    exaTime.nextPoolID()
                  );
                });

                it("THEN the Maturity Pool is even", async () => {
                  expect(mp.borrowed - mp.supplied).to.equal(0);
                });

                it("THEN the debt of the smart pool is 0", async () => {
                  expect(mp.suppliedSP).to.equal(0);
                });
              });
            });
          });
        });
      });
    });
  });

  describe("Tests seconds' precision", async () => {
    beforeEach(async () => {
      poolEnv = await PoolEnv.create();
    });
    describe("GIVEN 100k tokens are borrowed from a maturity of 10 days (10k in fees)", async () => {
      let mp: any;
      let mockedDate = exaTime.timestamp + exaTime.ONE_HOUR; // we add one hour so it's not the same timestamp than previous blocks
      let fakeMaturityPool = mockedDate + exaTime.ONE_DAY * 10;
      const fees = 10000;
      const borrowedAmount = 100000;

      beforeEach(async () => {
        await poolEnv.moveInTime(mockedDate);
        await poolEnv.takeMoneyAndAddFee(
          fakeMaturityPool,
          borrowedAmount.toString(),
          fees.toString()
        );
      });

      describe("AND WHEN we move in time 10 hours later AND a deposit of 100k is made", async () => {
        const depositedAmount = 100000;
        const mockedDate10Hours = mockedDate + exaTime.ONE_HOUR * 10;

        beforeEach(async () => {
          await poolEnv.moveInTime(mockedDate10Hours);
          await poolEnv.addMoney(fakeMaturityPool, depositedAmount.toString());
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'borrowed' is 100k", async () => {
          expect(mp.borrowed).to.equal(parseUnits("100000"));
        });

        it("THEN the pool 'supplied' is 100k", async () => {
          expect(mp.supplied).to.equal(parseUnits("100000"));
        });

        it("THEN the pool 'unassignedEarnings' are close to 4790", async () => {
          let unassignedEarnings =
            poolEnv.calculateUnassignedEarningsWhenDepositingToMP(
              fakeMaturityPool,
              mockedDate10Hours,
              fees, // previous unassigned earnings
              exaTime.ONE_HOUR * 10, // seconds since last accrue
              depositedAmount,
              borrowedAmount
            );

          expect(mp.unassignedEarnings).to.closeTo(
            parseUnits(unassignedEarnings.toFixed(8).toString()),
            parseUnits("0.00000001").toNumber()
          );
          // (10000-(10000*36000)/(10*24*60*60)) / 2
          expect(mp.unassignedEarnings).to.closeTo(
            parseUnits("4791.666"),
            parseUnits("0000.001").toNumber()
          );
        });

        it("THEN the pool 'earningsSP' are close to 415", async () => {
          let earningsSP = poolEnv.calculateEarningsSP(
            fakeMaturityPool,
            mockedDate10Hours,
            0, // previous earningsSP
            fees, // previous unassigned earnings
            exaTime.ONE_HOUR * 10 // 10 hours in seconds since last accrue
          );

          expect(mp.earningsSP).to.closeTo(
            parseUnits(earningsSP.toFixed(8).toString()),
            parseUnits("0.00000001").toNumber()
          );
          expect(mp.earningsSP).to.closeTo(
            parseUnits("416.666"),
            parseUnits("000.001").toNumber()
          );
        });

        it("THEN the smart pool total debt is 100k", async () => {
          let smartPoolTotalDebt = await poolEnv.mpHarness.smartPoolTotalDebt();
          expect(smartPoolTotalDebt).to.equal(parseUnits("100000"));
        });

        it("THEN the pool 'lastFee' is close to 4790", async () => {
          let previousUnassignedEarnings = poolEnv.calculateUnassignedEarnings(
            fakeMaturityPool,
            mockedDate10Hours,
            fees, // previous unassigned earnings
            exaTime.ONE_HOUR * 10, // ten hours in seconds since last accrue
            0 // new fee
          );
          let lastFee = poolEnv.calculateLastFee(
            previousUnassignedEarnings,
            depositedAmount,
            borrowedAmount
          );

          expect(await poolEnv.mpHarness.lastFee()).to.closeTo(
            parseUnits(lastFee.toFixed(8).toString()),
            parseUnits("0.00000001").toNumber()
          );
          expect(await poolEnv.mpHarness.lastFee()).to.closeTo(
            parseUnits("4791.666"),
            parseUnits("0000.001").toNumber()
          );
        });
      });

      describe("AND GIVEN we move in time to day 5 AND a deposit of 100k is made", async () => {
        const depositedAmount = 100000;
        const mockedDate5Days = mockedDate + exaTime.ONE_DAY * 5;

        beforeEach(async () => {
          await poolEnv.moveInTime(mockedDate5Days);
          await poolEnv.addMoney(fakeMaturityPool, depositedAmount.toString());
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'unassignedEarnings' are 2.5k", async () => {
          let unassignedEarnings =
            poolEnv.calculateUnassignedEarningsWhenDepositingToMP(
              fakeMaturityPool,
              mockedDate5Days,
              fees, // previous unassigned earnings
              exaTime.ONE_DAY * 5, // seconds since last accrue
              depositedAmount,
              borrowedAmount
            );

          expect(mp.unassignedEarnings).to.eq(
            parseUnits(unassignedEarnings.toString())
          );
          expect(mp.unassignedEarnings).to.equal(parseUnits("2500"));
        });

        it("THEN the pool 'earningsSP' are 5k", async () => {
          let earningsSP = poolEnv.calculateEarningsSP(
            fakeMaturityPool,
            mockedDate5Days,
            0, // previous earningsSP
            fees, // previous unassigned earnings
            exaTime.ONE_DAY * 5 // five days in seconds since last accrue
          );

          expect(mp.earningsSP).to.eq(parseUnits(earningsSP.toString()));
          expect(mp.earningsSP).to.equal(parseUnits("5000"));
        });

        it("THEN the pool 'lastFee' is 2.5k", async () => {
          let previousUnassignedEarnings = poolEnv.calculateUnassignedEarnings(
            fakeMaturityPool,
            mockedDate5Days,
            fees, // previous unassigned earnings
            exaTime.ONE_DAY * 5, // five days in seconds since last accrue
            0 // new fee
          );
          let lastFee = poolEnv.calculateLastFee(
            previousUnassignedEarnings,
            depositedAmount,
            borrowedAmount
          );

          expect(await poolEnv.mpHarness.lastFee()).to.eq(
            parseUnits(lastFee.toString())
          );
          expect(await poolEnv.mpHarness.lastFee()).to.equal(
            parseUnits("2500")
          );
        });
        describe("AND GIVEN we move in time 2 days more AND a borrow of 50k is made (5k in fees)", async () => {
          const mockedDate7Days = mockedDate5Days + exaTime.ONE_DAY * 2;
          const newBorrowedAmount = 50000;
          const newFees = 5000;

          beforeEach(async () => {
            await poolEnv.moveInTime(mockedDate7Days);
            await poolEnv.takeMoneyAndAddFee(
              fakeMaturityPool,
              newBorrowedAmount.toString(),
              newFees.toString()
            );
            mp = await poolEnv.mpHarness.maturityPool();
          });

          it("THEN the pool 'borrowed' is 150k", async () => {
            expect(mp.borrowed).to.equal(parseUnits("150000"));
          });

          it("THEN the pool 'supplied' is 100k", async () => {
            expect(mp.supplied).to.equal(parseUnits("100000"));
          });

          it("THEN the pool 'unassignedEarnings' are 6500", async () => {
            let unassignedEarnings = poolEnv.calculateUnassignedEarnings(
              fakeMaturityPool,
              mockedDate7Days,
              2500, // previous unassigned earnings
              exaTime.ONE_DAY * 2, // 2 days passed since last accrual
              newFees
            );

            expect(mp.unassignedEarnings).to.eq(
              parseUnits(unassignedEarnings.toString())
            );
            expect(mp.unassignedEarnings).to.equal(parseUnits("6500"));
          });

          it("THEN the pool 'earningsSP' are 6k", async () => {
            let earningsSP = poolEnv.calculateEarningsSP(
              fakeMaturityPool,
              mockedDate7Days,
              5000, // previous earningsSP
              2500, // previous unassigned earnings
              exaTime.ONE_DAY * 2 // 2 days in seconds since last accrual
            );

            expect(mp.earningsSP).to.eq(parseUnits(earningsSP.toString()));
            expect(mp.earningsSP).to.equal(parseUnits("6000"));
          });

          it("THEN the smart pool total debt is 100k", async () => {
            let smartPoolTotalDebt =
              await poolEnv.mpHarness.smartPoolTotalDebt();
            expect(smartPoolTotalDebt).to.equal(parseUnits("100000"));
          });
        });
      });

      describe("AND WHEN we move in time to day 8 with 1 hour and 23 seconds AND a deposit of 100k is made", async () => {
        const depositedAmount = 100000;
        const mockedDate8DaysWithHoursAndSeconds =
          mockedDate +
          exaTime.ONE_DAY * 8 +
          exaTime.ONE_HOUR * 1 +
          exaTime.ONE_SECOND * 23;
        let unassignedEarnings: number;

        beforeEach(async () => {
          await poolEnv.moveInTime(mockedDate8DaysWithHoursAndSeconds);
          await poolEnv.addMoney(fakeMaturityPool, depositedAmount.toString());

          mp = await poolEnv.mpHarness.maturityPool();
          unassignedEarnings = mp.unassignedEarnings;
        });

        it("THEN the pool 'unassignedEarnings' are correctly accounted", async () => {
          let unassignedEarnings =
            poolEnv.calculateUnassignedEarningsWhenDepositingToMP(
              fakeMaturityPool,
              mockedDate8DaysWithHoursAndSeconds,
              fees, // previous unassigned earnings
              exaTime.ONE_DAY * 8 +
                exaTime.ONE_HOUR * 1 +
                exaTime.ONE_SECOND * 23, // total seconds since last accrue
              depositedAmount,
              borrowedAmount
            );

          expect(mp.unassignedEarnings).to.closeTo(
            parseUnits(unassignedEarnings.toFixed(8).toString()),
            parseUnits("0.00000001").toNumber()
          );
        });

        it("THEN the pool 'earningsSP' are correctly accrued", async () => {
          let earningsSP = poolEnv.calculateEarningsSP(
            fakeMaturityPool,
            mockedDate8DaysWithHoursAndSeconds,
            0, // previous earningsSP
            fees, // previous unassigned earnings
            exaTime.ONE_DAY * 8 + exaTime.ONE_HOUR * 1 + exaTime.ONE_SECOND * 23 // total seconds since last accrue
          );

          expect(mp.earningsSP).to.closeTo(
            parseUnits(earningsSP.toFixed(8).toString()),
            parseUnits("0.00000001").toNumber()
          );
        });

        it("THEN the pool 'lastFee' is correctly accounted", async () => {
          let previousUnassignedEarnings = poolEnv.calculateUnassignedEarnings(
            fakeMaturityPool,
            mockedDate8DaysWithHoursAndSeconds,
            fees, // previous unassigned earnings
            exaTime.ONE_DAY * 8 +
              exaTime.ONE_HOUR * 1 +
              exaTime.ONE_SECOND * 23, // total seconds since last accrue
            0 // new fee
          );
          let lastFee = poolEnv.calculateLastFee(
            previousUnassignedEarnings,
            depositedAmount,
            borrowedAmount
          );

          expect(await poolEnv.mpHarness.lastFee()).to.closeTo(
            parseUnits(lastFee.toFixed(8).toString()),
            parseUnits("0.00000001").toNumber()
          );
        });

        describe("AND GIVEN we reach maturity AND a repay of 100k is made", async () => {
          beforeEach(async () => {
            await poolEnv.moveInTime(fakeMaturityPool);
            await poolEnv.repay(fakeMaturityPool, borrowedAmount.toString());
            mp = await poolEnv.mpHarness.maturityPool();
          });

          it("THEN the pool 'borrowed' is 0", async () => {
            expect(mp.borrowed).to.equal(parseUnits("0"));
          });

          it("THEN the pool 'supplied' is 100k", async () => {
            expect(mp.supplied).to.equal(parseUnits("100000"));
          });

          it("THEN the pool 'unassignedEarnings' are 0", async () => {
            let currentUnassignedEarnings = poolEnv.calculateUnassignedEarnings(
              fakeMaturityPool, // maturity pool date
              fakeMaturityPool, // current block timestamp
              unassignedEarnings, // previous unassigned earnings
              exaTime.ONE_DAY * 1 +
                exaTime.ONE_HOUR * 23 -
                exaTime.ONE_SECOND * 23, // 1 day, 22 hours, 59 min and 37 seconds passed since last accrue
              0
            );

            expect(mp.unassignedEarnings).to.eq(
              parseUnits(currentUnassignedEarnings.toString())
            );
            expect(mp.unassignedEarnings).to.equal(parseUnits("0"));
          });

          it("THEN the smart pool total debt is 979 approximately (earningsMP for depositors by the pool)", async () => {
            let smartPoolTotalDebt =
              await poolEnv.mpHarness.smartPoolTotalDebt();
            expect(smartPoolTotalDebt).to.gt(parseUnits("979"));
            expect(smartPoolTotalDebt).to.lt(parseUnits("980"));
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
