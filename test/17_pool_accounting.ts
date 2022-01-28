import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ProtocolError, errorGeneric, ExaTime } from "./exactlyUtils";

describe("PoolAccounting", () => {
  let laura: SignerWithAddress;
  let realPoolAccounting: Contract;
  let poolAccounting: Contract;
  let mockedInterestRateModel: Contract;
  let exaTime = new ExaTime();
  let snapshot: any;
  const nextPoolID = exaTime.nextPoolID();
  // we use a high maxSPDebt limit since max borrows are already tested
  const maxSPDebt = parseUnits("100000");

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
    [, laura] = await ethers.getSigners();

    const MockedInterestRateModel = await ethers.getContractFactory(
      "MockedInterestRateModel"
    );
    mockedInterestRateModel = await MockedInterestRateModel.deploy();
    await mockedInterestRateModel.deployed();
    const TSUtilsLib = await ethers.getContractFactory("TSUtils");
    let tsUtils = await TSUtilsLib.deploy();
    await tsUtils.deployed();
    const PoolLib = await ethers.getContractFactory("PoolLib", {
      libraries: {
        TSUtils: tsUtils.address,
      },
    });
    let poolLib = await PoolLib.deploy();
    await poolLib.deployed();

    const PoolAccounting = await ethers.getContractFactory("PoolAccounting", {
      libraries: {
        TSUtils: tsUtils.address,
        PoolLib: poolLib.address,
      },
    });
    realPoolAccounting = await PoolAccounting.deploy(
      mockedInterestRateModel.address
    );
    await realPoolAccounting.deployed();
    const PoolAccountingHarness = await ethers.getContractFactory(
      "PoolAccountingHarness"
    );
    poolAccounting = await PoolAccountingHarness.deploy(
      realPoolAccounting.address
    );
    await poolAccounting.deployed();

    await realPoolAccounting.initialize(poolAccounting.address);
  });

  describe("function calls not originating from the FixedLender contract", () => {
    it("WHEN invoking borrowMP NOT from the FixedLender, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        realPoolAccounting.borrowMP(0, laura.address, 0, 0, 0)
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.CALLER_MUST_BE_FIXED_LENDER)
      );
    });

    it("WHEN invoking depositMP NOT from the FixedLender, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        realPoolAccounting.depositMP(0, laura.address, 0, 0)
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.CALLER_MUST_BE_FIXED_LENDER)
      );
    });

    it("WHEN invoking repayMP NOT from the FixedLender, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        realPoolAccounting.repayMP(0, laura.address, 0)
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.CALLER_MUST_BE_FIXED_LENDER)
      );
    });

    it("WHEN invoking withdrawMP NOT from the FixedLender, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        realPoolAccounting.withdrawMP(0, laura.address, 0, 0)
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

    beforeEach(async () => {
      await ethers.provider.send("evm_setNextBlockTimestamp", [
        sixDaysToMaturity,
      ]);
      depositAmount = "10000";
      await poolAccounting
        .connect(laura)
        .depositMP(
          nextPoolID,
          laura.address,
          parseUnits(depositAmount),
          parseUnits(depositAmount)
        );
      returnValues = await poolAccounting.returnValues();
    });
    it("THEN the maturity pool state is correctly updated", async () => {
      const mp = await realPoolAccounting.maturityPools(nextPoolID);

      expect(mp.borrowed).to.eq(parseUnits("0"));
      expect(mp.supplied).to.eq(parseUnits(depositAmount));
      expect(mp.suppliedSP).to.eq(parseUnits("0"));
      expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
      expect(mp.earningsSP).to.eq(parseUnits("0"));
      expect(mp.lastAccrue).to.eq(sixDaysToMaturity);
    });
    it("THEN the currentTotalDeposit returned is equal to the amount (no fees earned)", async () => {
      expect(returnValues.currentTotalDeposit).to.eq(parseUnits(depositAmount));
    });

    describe("AND GIVEN a borrowMP with an amount of 5000 (250 charged in fees)", () => {
      const fourDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 4;

      beforeEach(async () => {
        await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await ethers.provider.send("evm_setNextBlockTimestamp", [
          fourDaysToMaturity,
        ]);
        borrowAmount = 5000;
        borrowFees = 250;
        await poolAccounting
          .connect(laura)
          .borrowMP(
            nextPoolID,
            laura.address,
            parseUnits(borrowAmount.toString()),
            parseUnits((borrowAmount + borrowFees).toString()),
            maxSPDebt
          );
        returnValues = await poolAccounting.returnValues();
      });
      it("THEN the maturity pool state is correctly updated", async () => {
        const mp = await realPoolAccounting.maturityPools(nextPoolID);

        expect(mp.borrowed).to.eq(parseUnits(borrowAmount.toString()));
        expect(mp.supplied).to.eq(parseUnits(depositAmount));
        expect(mp.suppliedSP).to.eq(parseUnits("0"));
        expect(mp.unassignedEarnings).to.eq(parseUnits(borrowFees.toString())); // 5000 x 0,05 (5%)
        expect(mp.earningsSP).to.eq(parseUnits("0"));
        expect(mp.lastAccrue).to.eq(fourDaysToMaturity);
      });
      it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
        expect(returnValues.totalOwedNewBorrow).to.eq(
          parseUnits((borrowAmount + borrowFees).toString())
        );
      });

      describe("AND GIVEN another borrowMP call with an amount of 5000 (250 charged in fees)", () => {
        const threeDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 3;

        beforeEach(async () => {
          await ethers.provider.send("evm_setNextBlockTimestamp", [
            threeDaysToMaturity,
          ]);
          borrowAmount = 5000;
          borrowFees = 250;
          await poolAccounting
            .connect(laura)
            .borrowMP(
              nextPoolID,
              laura.address,
              parseUnits(borrowAmount.toString()),
              parseUnits((borrowAmount + borrowFees).toString()),
              maxSPDebt
            );
          returnValues = await poolAccounting.returnValues();
        });
        it("THEN the maturity pool state is correctly updated", async () => {
          const mp = await realPoolAccounting.maturityPools(nextPoolID);

          expect(mp.borrowed).to.eq(parseUnits((borrowAmount * 2).toString()));
          expect(mp.supplied).to.eq(parseUnits(depositAmount.toString()));
          expect(mp.suppliedSP).to.eq(parseUnits("0"));
          expect(mp.unassignedEarnings).to.eq(
            parseUnits((borrowFees + borrowFees - borrowFees / 4).toString()) // 250 + 250 - 250 / 4
          );
          expect(mp.earningsSP).to.eq(parseUnits((borrowFees / 4).toString())); // 250 / 4
          expect(mp.lastAccrue).to.eq(threeDaysToMaturity);
        });
        it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
          expect(returnValues.totalOwedNewBorrow).to.eq(
            parseUnits((borrowAmount + borrowFees).toString())
          );
        });

        describe("AND GIVEN another borrowMP call with an amount of 5000 (250 charged in fees)", () => {
          const twoDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 2;

          beforeEach(async () => {
            await ethers.provider.send("evm_setNextBlockTimestamp", [
              twoDaysToMaturity,
            ]);
            borrowAmount = 5000;
            borrowFees = 250;
            await poolAccounting
              .connect(laura)
              .borrowMP(
                nextPoolID,
                laura.address,
                parseUnits(borrowAmount.toString()),
                parseUnits((borrowAmount + borrowFees).toString()),
                maxSPDebt
              );
            returnValues = await poolAccounting.returnValues();
          });
          it("THEN the maturity pool state is correctly updated", async () => {
            const mp = await realPoolAccounting.maturityPools(nextPoolID);

            expect(mp.borrowed).to.eq(
              parseUnits((borrowAmount * 3).toString())
            );
            expect(mp.supplied).to.eq(parseUnits(depositAmount));
            expect(mp.suppliedSP).to.eq(parseUnits(borrowAmount.toString()));
            expect(mp.unassignedEarnings).to.be.lt(
              parseUnits((borrowFees + 437.5 - 437.5 / 3 + 1).toString()) // 437.5 = previous unassigned earnings
            );
            expect(mp.unassignedEarnings).to.be.gt(
              parseUnits((borrowFees + 437.5 - 437.5 / 3 - 1).toString())
            );
            expect(mp.earningsSP).to.be.lt(
              parseUnits((62.5 + 437.5 / 3 + 1).toString()) // 62.5 = previous earnings SP
            );
            expect(mp.earningsSP).to.be.gt(
              parseUnits((62.5 + 437.5 / 3 - 1).toString())
            );
            expect(mp.lastAccrue).to.eq(twoDaysToMaturity);
          });
          it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
            expect(returnValues.totalOwedNewBorrow).to.eq(
              parseUnits((borrowAmount + borrowFees).toString())
            );
          });

          describe("AND GIVEN another depositMP with an amount of 10000 (180 fees earned)", () => {
            const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY;

            beforeEach(async () => {
              await ethers.provider.send("evm_setNextBlockTimestamp", [
                oneDayToMaturity,
              ]);
              depositAmount = 10000;
              await poolAccounting
                .connect(laura)
                .depositMP(
                  nextPoolID,
                  laura.address,
                  parseUnits(depositAmount.toString()),
                  parseUnits(depositAmount.toString())
                );
              returnValues = await poolAccounting.returnValues();
            });
            it("THEN the maturity pool state is correctly updated", async () => {
              const mp = await realPoolAccounting.maturityPools(nextPoolID);
              const earnedFees =
                ((542 / 2) * depositAmount) / (depositAmount + borrowAmount); // 542 = previous unassigned earnings
              const unassignedEarnings = 542 / 2 - earnedFees;

              expect(mp.borrowed).to.eq(
                parseUnits((borrowAmount * 3).toString()) // 3 borrows of 5k where made
              );
              expect(mp.supplied).to.eq(
                parseUnits((depositAmount * 2).toString()) // 2 deposits of 10k where made
              );
              expect(mp.suppliedSP).to.eq(parseUnits(borrowAmount.toString()));
              expect(mp.unassignedEarnings).to.be.lt(
                parseUnits(unassignedEarnings.toString())
              );
              expect(mp.unassignedEarnings).to.be.gt(
                parseUnits((unassignedEarnings - 1).toString())
              );
              expect(mp.earningsSP).to.be.lt(parseUnits("480")); // 209 + 542 / 2
              expect(mp.earningsSP).to.be.gt(parseUnits("479")); // 209 = previous earnings SP & 542 = previous unassigned earnings
              expect(mp.lastAccrue).to.eq(oneDayToMaturity);
            });
            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValues.currentTotalDeposit).to.be.lt(
                parseUnits((depositAmount + 181).toString()) // 542 / 3
              );
              expect(returnValues.currentTotalDeposit).to.be.gt(
                parseUnits((depositAmount + 180).toString())
              );
            });
          });

          describe("AND GIVEN another depositMP with an exorbitant amount of 100M (almost all fees earned)", () => {
            const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY;

            beforeEach(async () => {
              await ethers.provider.send("evm_setNextBlockTimestamp", [
                oneDayToMaturity,
              ]);
              depositAmount = 100000000;
              await poolAccounting
                .connect(laura)
                .depositMP(
                  nextPoolID,
                  laura.address,
                  parseUnits(depositAmount.toString()),
                  parseUnits(depositAmount.toString())
                );
              returnValues = await poolAccounting.returnValues();
            });
            it("THEN the maturity pool state is correctly updated (unassignedEarnings are close to 0 but not 0)", async () => {
              const mp = await realPoolAccounting.maturityPools(nextPoolID);

              expect(mp.borrowed).to.eq(
                parseUnits((borrowAmount * 3).toString()) // 3 borrows of 5k where made
              );
              expect(mp.supplied).to.eq(
                parseUnits((depositAmount + 10000).toString()) // 10000 = previous deposited amount
              );
              expect(mp.suppliedSP).to.eq(parseUnits(borrowAmount.toString())); // 5k
              expect(mp.unassignedEarnings).to.be.lt(parseUnits("0.1")); // after a very big deposit compared to the suppliedSP, almost no unassignedEarnings are left
              expect(mp.unassignedEarnings).to.be.gt(parseUnits("0"));
              expect(mp.earningsSP).to.be.lt(parseUnits("480")); // 209 + 542 / 2
              expect(mp.earningsSP).to.be.gt(parseUnits("479")); // 209 = previous earnings SP & 542 = previous unassigned earnings
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

            describe("AND GIVEN a repayMP with an amount of 5250", () => {
              const twelveHoursToMaturity =
                nextPoolID - exaTime.ONE_DAY + exaTime.ONE_HOUR * 12;

              beforeEach(async () => {
                await ethers.provider.send("evm_setNextBlockTimestamp", [
                  twelveHoursToMaturity,
                ]);
                repayAmount = 5250;
                await poolAccounting
                  .connect(laura)
                  .repayMP(
                    nextPoolID,
                    laura.address,
                    parseUnits(repayAmount.toString())
                  );
                returnValues = await poolAccounting.returnValues();
              });
              it("THEN the maturity pool state is correctly updated", async () => {
                const mp = await realPoolAccounting.maturityPools(nextPoolID);

                expect(mp.borrowed).to.eq(
                  parseUnits((borrowAmount * 3 - repayAmount).toString()) // 3 borrows of 5k where made
                );
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()) // 1M + 10k deposit
                );
                expect(mp.suppliedSP).to.eq(
                  parseUnits(borrowAmount.toString())
                );
                expect(mp.unassignedEarnings).to.be.lt(parseUnits("0.01"));
                expect(mp.unassignedEarnings).to.be.gt(parseUnits("0"));
                expect(mp.earningsSP).to.be.lt(parseUnits("480")); // earnings added are inappreciable
                expect(mp.earningsSP).to.be.gt(parseUnits("479"));
                expect(mp.lastAccrue).to.eq(twelveHoursToMaturity);
              });
              it("THEN the return values are correctly calculated", async () => {
                expect(returnValues.penalties).to.be.eq(parseUnits("0"));
                expect(returnValues.debtCovered).to.be.eq(
                  parseUnits(repayAmount.toString())
                );
                expect(returnValues.fee).to.be.eq(parseUnits("0"));
                expect(returnValues.earningsRepay).to.eq(parseUnits("0"));
              });
            });

            describe("AND GIVEN a total repayMP with an amount of 15750 (all debt)", () => {
              const twelveHoursToMaturity =
                nextPoolID - exaTime.ONE_DAY + exaTime.ONE_HOUR * 12;

              beforeEach(async () => {
                await ethers.provider.send("evm_setNextBlockTimestamp", [
                  twelveHoursToMaturity,
                ]);
                repayAmount = 15750;
                await poolAccounting
                  .connect(laura)
                  .repayMP(
                    nextPoolID,
                    laura.address,
                    parseUnits(repayAmount.toString())
                  );
                returnValues = await poolAccounting.returnValues();
              });
              it("THEN the maturity pool state is correctly updated", async () => {
                const mp = await realPoolAccounting.maturityPools(nextPoolID);

                expect(mp.borrowed).to.eq(parseUnits("0"));
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()) // 1M + 10k deposit
                );
                expect(mp.suppliedSP).to.eq(parseUnits("0"));
              });
              it("THEN the return values are correctly calculated", async () => {
                expect(returnValues.penalties).to.be.eq(parseUnits("0"));
                expect(returnValues.debtCovered).to.be.eq(
                  parseUnits(repayAmount.toString())
                );
                expect(returnValues.fee).to.be.lt(parseUnits("480"));
                expect(returnValues.fee).to.be.gt(parseUnits("479"));
                expect(returnValues.earningsRepay).to.eq(parseUnits("0"));
              });
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
