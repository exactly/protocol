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
  let realPoolAccounting: Contract;
  let mockedInterestRateModel: Contract;
  let fixedLender: Contract;
  let exaTime = new ExaTime();
  let snapshot: any;
  const nextPoolID = exaTime.nextPoolID() + 7 * exaTime.ONE_DAY; // we add 7 days so we make sure we are far from the previouos timestamp blocks
  const maxSPDebt = parseUnits("100000"); // we use a high maxSPDebt limit since max borrows are already tested

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
    [, laura] = await ethers.getSigners();
    poolAccountingEnv = await PoolAccountingEnv.create();
    realPoolAccounting = poolAccountingEnv.realPoolAccounting;
    poolAccountingHarness = poolAccountingEnv.poolAccountingHarness;
    mockedInterestRateModel = poolAccountingEnv.interestRateModel;
    fixedLender = poolAccountingEnv.fixedLender;
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
    let mp: any;

    beforeEach(async () => {
      await ethers.provider.send("evm_setNextBlockTimestamp", [
        sixDaysToMaturity,
      ]);
      depositAmount = "10000";
      await poolAccountingHarness
        .connect(laura)
        .depositMP(
          nextPoolID,
          laura.address,
          parseUnits(depositAmount),
          parseUnits(depositAmount)
        );
      returnValues = await poolAccountingHarness.returnValues();
      mp = await realPoolAccounting.maturityPools(nextPoolID);
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
    it("THEN unassignedEarnings are 0", async () => {
      expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
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

    describe("AND GIVEN a borrowMP with an amount of 5000 (250 charged in fees)", () => {
      const fourDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 4;
      let mp: any;
      beforeEach(async () => {
        await mockedInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await ethers.provider.send("evm_setNextBlockTimestamp", [
          fourDaysToMaturity,
        ]);
        borrowAmount = 5000;
        borrowFees = 250;
        await poolAccountingHarness
          .connect(laura)
          .borrowMP(
            nextPoolID,
            laura.address,
            parseUnits(borrowAmount.toString()),
            parseUnits((borrowAmount + borrowFees).toString()),
            maxSPDebt
          );
        returnValues = await poolAccountingHarness.returnValues();
        mp = await realPoolAccounting.maturityPools(nextPoolID);
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
      it("THEN unassignedEarnings are 5000 x 0,05 (5%)", async () => {
        expect(mp.unassignedEarnings).to.eq(parseUnits(borrowFees.toString())); // 5000 x 0,05 (5%)
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

      describe("AND GIVEN another borrowMP call with an amount of 5000 (250 charged in fees)", () => {
        const threeDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 3;
        let mp: any;
        beforeEach(async () => {
          await ethers.provider.send("evm_setNextBlockTimestamp", [
            threeDaysToMaturity,
          ]);
          borrowAmount = 5000;
          borrowFees = 250;
          await poolAccountingHarness
            .connect(laura)
            .borrowMP(
              nextPoolID,
              laura.address,
              parseUnits(borrowAmount.toString()),
              parseUnits((borrowAmount + borrowFees).toString()),
              maxSPDebt
            );
          returnValues = await poolAccountingHarness.returnValues();
          mp = await realPoolAccounting.maturityPools(nextPoolID);
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
        it("THEN unassignedEarnings are 250 + 250 - 250 / 4", async () => {
          expect(mp.unassignedEarnings).to.eq(
            parseUnits((borrowFees + borrowFees - borrowFees / 4).toString()) // 250 + 250 - 250 / 4
          );
        });
        it("THEN earningsSP are 250 / 4", async () => {
          expect(mp.earningsSP).to.eq(parseUnits((borrowFees / 4).toString())); // 250 / 4
        });
        it("THEN the maturity pool state is correctly updated", async () => {
          expect(mp.lastAccrue).to.eq(threeDaysToMaturity);
        });
        it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
          expect(returnValues.totalOwedNewBorrow).to.eq(
            parseUnits((borrowAmount + borrowFees).toString())
          );
        });

        describe("AND GIVEN another borrowMP call with an amount of 5000 (250 charged in fees)", () => {
          const twoDaysToMaturity = nextPoolID - exaTime.ONE_DAY * 2;
          let mp: any;
          beforeEach(async () => {
            await ethers.provider.send("evm_setNextBlockTimestamp", [
              twoDaysToMaturity,
            ]);
            borrowAmount = 5000;
            borrowFees = 250;
            await poolAccountingHarness
              .connect(laura)
              .borrowMP(
                nextPoolID,
                laura.address,
                parseUnits(borrowAmount.toString()),
                parseUnits((borrowAmount + borrowFees).toString()),
                maxSPDebt
              );
            returnValues = await poolAccountingHarness.returnValues();
            mp = await realPoolAccounting.maturityPools(nextPoolID);
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
          it("THEN unassignedEarnings around 437.5", async () => {
            expect(mp.unassignedEarnings).to.be.lt(
              parseUnits((borrowFees + 437.5 - 437.5 / 3 + 1).toString()) // 437.5 = previous unassigned earnings
            );
            expect(mp.unassignedEarnings).to.be.gt(
              parseUnits((borrowFees + 437.5 - 437.5 / 3 - 1).toString())
            );
          });
          it("THEN earningsSP are around 62.5", async () => {
            expect(mp.earningsSP).to.be.lt(
              parseUnits((62.5 + 437.5 / 3 + 1).toString()) // 62.5 = previous earnings SP
            );
            expect(mp.earningsSP).to.be.gt(
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

          describe("AND GIVEN another depositMP with an amount of 10000 (180 fees earned)", () => {
            const oneDayToMaturity = nextPoolID - exaTime.ONE_DAY;
            let mp: any;
            beforeEach(async () => {
              await ethers.provider.send("evm_setNextBlockTimestamp", [
                oneDayToMaturity,
              ]);
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
              mp = await realPoolAccounting.maturityPools(nextPoolID);
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
                parseUnits((depositAmount + 181).toString()) // 542 / 3
              );
              expect(returnValues.currentTotalDeposit).to.be.gt(
                parseUnits((depositAmount + 180).toString())
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
              mp = await realPoolAccounting.maturityPools(nextPoolID);
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
              await ethers.provider.send("evm_setNextBlockTimestamp", [
                oneDayToMaturity,
              ]);
              depositAmount = 100000000;
              await poolAccountingHarness
                .connect(laura)
                .depositMP(
                  nextPoolID,
                  laura.address,
                  parseUnits(depositAmount.toString()),
                  parseUnits(depositAmount.toString())
                );

              returnValues = await poolAccountingHarness.returnValues();
              mp = await realPoolAccounting.maturityPools(nextPoolID);
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

            it("THEN suppliedSP is equal to borrowAmount (5k)", async () => {
              expect(mp.suppliedSP).to.eq(parseUnits(borrowAmount.toString())); // 5k
            });

            it("THEN unassignedEarnings are almost 0", async () => {
              expect(mp.unassignedEarnings).to.be.lt(parseUnits("0.1")); // after a very big deposit compared to the suppliedSP, almost no unassignedEarnings are left
              expect(mp.unassignedEarnings).to.be.gt(parseUnits("0"));
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

            describe("AND GIVEN a repayMP with an amount of 5250", () => {
              const twelveHoursToMaturity =
                nextPoolID - exaTime.ONE_DAY + exaTime.ONE_HOUR * 12;

              beforeEach(async () => {
                await ethers.provider.send("evm_setNextBlockTimestamp", [
                  twelveHoursToMaturity,
                ]);
                repayAmount = 5250;
                await poolAccountingHarness
                  .connect(laura)
                  .repayMP(
                    nextPoolID,
                    laura.address,
                    parseUnits(repayAmount.toString())
                  );
                returnValues = await poolAccountingHarness.returnValues();
                mp = await realPoolAccounting.maturityPools(nextPoolID);
              });

              it("THEN borrowed is 3x repayAmount", async () => {
                expect(mp.borrowed).to.eq(
                  parseUnits((borrowAmount * 3 - repayAmount).toString()) // 3 borrows of 5k where made
                );
              });

              it("THEN supplied is 100M + 10k", async () => {
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()) // 100M + 10k deposit
                );
              });

              it("THEN suppliedSP is borrowAmount", async () => {
                expect(mp.suppliedSP).to.eq(
                  parseUnits(borrowAmount.toString())
                );
              });

              it("THEN unassignedEarnings are close to 0", async () => {
                expect(mp.unassignedEarnings).to.be.lt(parseUnits("0.01"));
                expect(mp.unassignedEarnings).to.be.gt(parseUnits("0"));
              });

              it("THEN the pool 'earningsMP' is repaid (=0)", async () => {
                expect(mp.earningsMP).to.be.gt(parseUnits("270"));
                expect(mp.earningsMP).to.be.lt(parseUnits("271"));
              });

              it("THEN earningsSP are around 479", async () => {
                expect(mp.earningsSP).to.be.lt(parseUnits("480")); // earnings added are inappreciable
                expect(mp.earningsSP).to.be.gt(parseUnits("479"));
              });

              it("THEN lastAccrue is 12 hours before maturity", async () => {
                expect(mp.lastAccrue).to.eq(twelveHoursToMaturity);
              });

              it("THEN the penalties were 0", async () => {
                expect(returnValues.penalties).to.be.eq(parseUnits("0"));
              });

              it("THEN the debtCovered was the full repayAmount", async () => {
                expect(returnValues.debtCovered).to.be.eq(
                  parseUnits(repayAmount.toString())
                );
              });

              it("THEN the fee was 0", async () => {
                expect(returnValues.fee).to.be.eq(parseUnits("0"));
              });

              it("THEN the earningsRepay was 0", async () => {
                expect(returnValues.earningsRepay).to.eq(parseUnits("0"));
              });
            });

            describe("AND GIVEN a total repayMP at maturity with an amount of 15750 (all debt)", () => {
              beforeEach(async () => {
                await ethers.provider.send("evm_setNextBlockTimestamp", [
                  nextPoolID,
                ]);
                repayAmount = 15750;
                await poolAccountingHarness
                  .connect(laura)
                  .repayMP(
                    nextPoolID,
                    laura.address,
                    parseUnits(repayAmount.toString())
                  );
                returnValues = await poolAccountingHarness.returnValues();
              });
              it("THEN the maturity pool state is correctly updated", async () => {
                const mp = await realPoolAccounting.maturityPools(nextPoolID);

                expect(mp.borrowed).to.eq(parseUnits("0"));
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()) // 1M + 10k deposit
                );
                expect(mp.suppliedSP).to.eq(parseUnits("0"));
              });

              it("THEN the penalties paid were 0", async () => {
                expect(returnValues.penalties).to.be.eq(parseUnits("0"));
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

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
