import { expect } from "chai";
import { parseUnits } from "ethers/lib/utils";
import { ethers } from "hardhat";
import { ExaTime } from "./exactlyUtils";
import { PoolEnv } from "./poolEnv";

describe("Pool Management Library", () => {
  const exaTime = new ExaTime();

  let poolEnv: PoolEnv;
  let snapshot: any;

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  describe("GIVEN a clean maturity pool", () => {
    beforeEach(async () => {
      poolEnv = await PoolEnv.create();
    });

    describe("WHEN 100 token are deposited", async () => {
      let mp: any;
      beforeEach(async () => {
        await poolEnv.addMoney(exaTime.nextPoolID(), "100");
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

      it("THEN the pool 'lastCommission' is 0", async () => {
        expect(await poolEnv.mpHarness.lastCommission()).to.equal(
          parseUnits("0")
        );
      });

      describe("AND WHEN 80 token are taken out, with 10 of fees to be paid", async () => {
        let mp: any;
        beforeEach(async () => {
          await poolEnv.takeMoney("80");
          await poolEnv.addFee(exaTime.nextPoolID(), "10");
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

        describe("AND WHEN 70 token are taken out, with 10 of fees to be paid", async () => {
          let mp: any;
          beforeEach(async () => {
            await poolEnv.takeMoney("70");
            await poolEnv.addFee(exaTime.nextPoolID(), "8");
            mp = await poolEnv.mpHarness.maturityPool();
          });

          it("THEN the pool 'borrowed' is 150", async () => {
            expect(mp.borrowed).to.equal(parseUnits("150"));
          });

          it("THEN the pool 'supplied' is 100", async () => {
            expect(mp.supplied).to.equal(parseUnits("100"));
          });

          it("THEN the pool 'earnings' at maturity are 18", async () => {
            expect(mp.unassignedEarnings).to.equal(parseUnits("18"));
          });

          it("THEN the pool 'earningsSP' are 0", async () => {
            expect(mp.earningsSP).to.equal(parseUnits("0"));
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
              // adding a 0 fee forces accruing
              await poolEnv.addFee(exaTime.nextPoolID(), "0");
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

            describe("AND WHEN one more day goes by, nothing changes", async () => {
              let mp: any;
              beforeEach(async () => {
                await poolEnv.moveInTime(exaTime.day(12));
                // adding a 0 fee forces accruing
                await poolEnv.addFee(exaTime.nextPoolID(), "0");
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
        await poolEnv.takeMoney("100");
        await poolEnv.addFee(exaTime.nextPoolID(), "10");
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
        await poolEnv.takeMoney("100");
        await poolEnv.addFee(exaTime.nextPoolID(), "10");
        await poolEnv.addMoney(exaTime.nextPoolID(), "100");
        mp = await poolEnv.mpHarness.maturityPool();
      });

      it("THEN the pool 'borrowed' is 100", async () => {
        expect(mp.borrowed).to.equal(parseUnits("100"));
      });

      it("THEN the pool 'unassignedEarnings' are 5", async () => {
        expect(mp.unassignedEarnings).to.equal(parseUnits("5"));
      });

      it("THEN the pool 'lastCommission' is 5", async () => {
        expect(await poolEnv.mpHarness.lastCommission()).to.equal(
          parseUnits("5")
        );
      });

      it("THEN the pool 'supplied' is 100", async () => {
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
        await poolEnv.takeMoney("100");
        await poolEnv.addFee(exaTime.nextPoolID(), "15");
        await poolEnv.addMoney(exaTime.nextPoolID(), "50");
        mp = await poolEnv.mpHarness.maturityPool();
      });

      it("THEN the pool 'borrowed' is 100", async () => {
        expect(mp.borrowed).to.equal(parseUnits("100"));
      });

      it("THEN the pool 'unassignedEarnings' are 10", async () => {
        expect(mp.unassignedEarnings).to.equal(parseUnits("10"));
      });

      it("THEN the pool 'lastCommission' is 5", async () => {
        expect(await poolEnv.mpHarness.lastCommission()).to.equal(
          parseUnits("5")
        );
      });

      it("THEN the pool 'supplied' is 50", async () => {
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
        await poolEnv.takeMoney("100");
        await poolEnv.addFee(exaTime.nextPoolID(), "60");
        await poolEnv.addMoney(exaTime.nextPoolID(), "500");
        mp = await poolEnv.mpHarness.maturityPool();
      });

      it("THEN the pool 'borrowed' is 100", async () => {
        expect(mp.borrowed).to.equal(parseUnits("100"));
      });

      it("THEN the pool 'unassignedEarnings' are 10", async () => {
        expect(mp.unassignedEarnings).to.equal(parseUnits("10"));
      });

      it("THEN the pool 'lastCommission' is 50", async () => {
        // all the commission went to the fixed rate deposit
        expect(await poolEnv.mpHarness.lastCommission()).to.equal(
          parseUnits("50")
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
    const fakeMaturityPool = exaTime.day(10);
    beforeEach(async () => {
      poolEnv = await PoolEnv.create();
      await poolEnv.takeMoney("100");
      await poolEnv.addFee(fakeMaturityPool, "10");
    });

    describe("WHEN 2 days go by and another user deposits 100 to the same Maturity Pool", async () => {
      let mp: any;
      beforeEach(async () => {
        await poolEnv.moveInTime(exaTime.day(2));
        await poolEnv.addMoney(fakeMaturityPool, "100");
        mp = await poolEnv.mpHarness.maturityPool();
      });

      it("THEN the pool 'earningsSP' is 2", async () => {
        expect(mp.earningsSP).to.equal(parseUnits("2"));
      });

      it("THEN the pool 'unassignedEarnings' are 4", async () => {
        expect(mp.unassignedEarnings).to.equal(parseUnits("4"));
      });

      it("THEN the pool 'lastCommission' is 4", async () => {
        expect(await poolEnv.mpHarness.lastCommission()).to.equal(
          parseUnits("4")
        );
      });

      describe("AND GIVEN more fees are generated 4 days after", () => {
        let mp: any;
        beforeEach(async () => {
          await poolEnv.moveInTime(exaTime.day(6));
          await poolEnv.takeMoney("100");
          await poolEnv.addFee(fakeMaturityPool, "10");
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'earningsSP' is 4", async () => {
          expect(mp.earningsSP).to.equal(parseUnits("4"));
        });

        it("THEN the pool 'unassignedEarnings' are 12", async () => {
          expect(mp.unassignedEarnings).to.eq(parseUnits("12"));
        });
      });

      describe("AND GIVEN that FOUR(4) more days go by and someone deposits 200", () => {
        let mp: any;
        beforeEach(async () => {
          await poolEnv.moveInTime(exaTime.day(6));
          await poolEnv.addMoney(fakeMaturityPool, "200");
          mp = await poolEnv.mpHarness.maturityPool();
        });

        it("THEN the pool 'earningsSP' is 4", async () => {
          expect(mp.earningsSP).to.equal(parseUnits("4"));
        });

        it("THEN the pool 'unassignedEarnings' are 0.666", async () => {
          expect(mp.unassignedEarnings).to.closeTo(
            parseUnits("0.6666"),
            parseUnits("0.0001").toNumber()
          );
        });

        it("THEN the pool 'lastCommission' is 1.3333", async () => {
          expect(await poolEnv.mpHarness.lastCommission()).to.closeTo(
            parseUnits("1.3333"),
            parseUnits("0.0001").toNumber()
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
