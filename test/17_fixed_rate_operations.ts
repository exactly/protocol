import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract, ContractTransaction } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { FixedPoolState } from "./exactlyUtils";
import { MarketEnv } from "./marketEnv";
import futurePools from "./utils/futurePools";

const { provider } = ethers;
const nextPoolID = futurePools(3)[2].toNumber();

describe("Fixed Rate Operations", () => {
  let laura: SignerWithAddress;
  let tina: SignerWithAddress;
  let marketEnv: MarketEnv;
  let marketHarness: Contract;
  let mockInterestRateModel: Contract;
  let asset: Contract;
  let snapshot: any;

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
    [, laura, tina] = await ethers.getSigners();
    marketEnv = await MarketEnv.create();
    marketHarness = marketEnv.marketHarness;
    mockInterestRateModel = marketEnv.mockInterestRateModel;
    asset = marketEnv.asset;

    await asset.mint(laura.address, parseUnits("20000000000"));
    await asset.connect(laura).approve(marketHarness.address, parseUnits("20000000000"));
    await marketHarness.connect(laura).deposit(parseUnits("10000000000"), laura.address);
  });

  describe("setPenaltyRate", () => {
    it("WHEN calling setPenaltyRate, THEN the penaltyRate should be updated", async () => {
      const penaltyRate = parseUnits("0.03").div(86_400);
      await marketHarness.setPenaltyRate(penaltyRate);
      expect(await marketHarness.penaltyRate()).to.be.equal(penaltyRate);
    });
    it("WHEN calling setPenaltyRate, THEN it should emit PenaltyRateSet event", async () => {
      const penaltyRate = parseUnits("0.04").div(86_400);
      await expect(await marketHarness.setPenaltyRate(penaltyRate))
        .to.emit(marketHarness, "PenaltyRateSet")
        .withArgs(penaltyRate);
    });
    it("WHEN calling setPenaltyRate from a regular (non-admin) user, THEN it reverts with an AccessControl error", async () => {
      await expect(marketHarness.connect(laura).setPenaltyRate(parseUnits("0.04"))).to.be.revertedWith("AccessControl");
    });
  });
  describe("setSmartPoolRate", () => {
    it("WHEN calling setBackupFeeRate function, THEN it should update backupFeeRate", async () => {
      await marketHarness.setBackupFeeRate(parseUnits("0.2"));
      expect(await marketHarness.backupFeeRate()).to.eq(parseUnits("0.2"));
    });
    it("WHEN calling setBackupFeeRate function, THEN it should emit BackupFeeRateSet", async () => {
      await expect(marketHarness.setBackupFeeRate(parseUnits("0.2")))
        .to.emit(marketHarness, "BackupFeeRateSet")
        .withArgs(parseUnits("0.2"));
    });
    it("WHEN calling setBackupFeeRate from a regular (non-admin) user, THEN it reverts with an AccessControl error", async () => {
      await expect(marketHarness.connect(laura).setBackupFeeRate(parseUnits("0.2"))).to.be.revertedWith(
        "AccessControl",
      );
    });
  });
  describe("setSmartPoolReserveFactor", () => {
    it("WHEN calling setSmartPoolReserveFactor, THEN the smartPoolReserveFactor should be updated", async () => {
      await marketHarness.setSmartPoolReserveFactor(parseUnits("0.04"));
      expect(await marketHarness.smartPoolReserveFactor()).to.be.equal(parseUnits("0.04"));
    });
    it("WHEN calling setSmartPoolReserveFactor, THEN it should emit SmartPoolReserveFactorSet event", async () => {
      await expect(await marketHarness.setSmartPoolReserveFactor(parseUnits("0.04")))
        .to.emit(marketHarness, "SmartPoolReserveFactorSet")
        .withArgs(parseUnits("0.04"));
    });
    it("WHEN calling setSmartPoolReserveFactor from a regular (non-admin) user, THEN it reverts with an AccessControl error", async () => {
      await expect(marketHarness.connect(laura).setSmartPoolReserveFactor(parseUnits("0.04"))).to.be.revertedWith(
        "AccessControl",
      );
    });
  });
  describe("setInterestRateModel", () => {
    let newInterestRateModel: Contract;
    before(async () => {
      const InterestRateModelFactory = await ethers.getContractFactory("InterestRateModel");

      newInterestRateModel = await InterestRateModelFactory.deploy(
        [parseUnits("0.75"), parseUnits("-0.105"), parseUnits("6")],
        parseUnits("4"),
        [parseUnits("0.75"), parseUnits("-0.105"), parseUnits("6")],
        parseUnits("4"),
      );
      await newInterestRateModel.deployed();
    });

    it("WHEN calling setInterestRateModel, THEN the interestRateModel should be updated", async () => {
      const interestRateModelBefore = await marketHarness.interestRateModel();
      await marketHarness.setInterestRateModel(newInterestRateModel.address);
      expect(await marketHarness.interestRateModel()).to.not.equal(interestRateModelBefore);
    });
    it("WHEN calling setInterestRateModel, THEN it should emit InterestRateModelSet event", async () => {
      await expect(await marketHarness.setInterestRateModel(newInterestRateModel.address))
        .to.emit(marketHarness, "InterestRateModelSet")
        .withArgs(newInterestRateModel.address);
    });
    it("WHEN calling setInterestRateModel from a regular (non-admin) user, THEN it reverts with an AccessControl error", async () => {
      await expect(marketHarness.connect(laura).setInterestRateModel(newInterestRateModel.address)).to.be.revertedWith(
        "AccessControl",
      );
    });
  });

  describe("GIVEN a depositMP with an amount of 10000 (0 fees earned)", () => {
    const sixDaysToMaturity = nextPoolID - 86_400 * 5;
    let depositAmount: any;
    let withdrawAmount: any;
    let borrowAmount: any;
    let borrowFees: any;
    let returnValue: any;
    let repayAmount: any;
    let fixedDepositPositions: any;
    let fixedBorrowPositions: any;
    let mp: any;
    let fixedPoolState: FixedPoolState;
    let tx: ContractTransaction;

    beforeEach(async () => {
      fixedPoolState = {
        borrowFees: parseUnits("0"),
        unassignedEarnings: parseUnits("0"),
        earningsSP: parseUnits("0"),
        earningsAccumulator: parseUnits("0"),
        earningsMP: parseUnits("0"),
        earningsDiscounted: parseUnits("0"),
      };

      depositAmount = "10000";

      marketEnv.switchWallet(laura);
      await marketEnv.moveInTime(sixDaysToMaturity);
      tx = await marketHarness
        .connect(laura)
        .depositMaturityWithReturnValue(
          nextPoolID,
          parseUnits(depositAmount),
          parseUnits(depositAmount),
          laura.address,
        );

      returnValue = await marketHarness.returnValue();
      mp = await marketHarness.fixedPools(nextPoolID);
      fixedDepositPositions = await marketHarness.fixedDepositPositions(nextPoolID, laura.address);
    });
    it("THEN borrowed equals 0", async () => {
      expect(mp.borrowed).to.eq(parseUnits("0"));
    });
    it("THEN supplied equals to depositedAmount", async () => {
      expect(mp.supplied).to.eq(parseUnits(depositAmount));
    });
    it("THEN unassignedEarnings are 0", async () => {
      expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
    });
    it("THEN lastAccrual is 6 days to maturity", async () => {
      expect(mp.lastAccrual).to.eq(sixDaysToMaturity);
    });
    it("THEN the fixedDepositPositions is correctly updated", async () => {
      expect(fixedDepositPositions[0]).to.be.eq(parseUnits(depositAmount.toString()));
      expect(fixedDepositPositions[1]).to.be.eq(parseUnits("0"));
    });
    it("THEN the earningsSP returned are 0", async () => {
      const smartPoolAssets = await marketHarness.smartPoolAssets();
      await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
    });
    it("THEN the currentTotalDeposit returned is equal to the amount (no fees earned)", async () => {
      expect(returnValue).to.eq(parseUnits(depositAmount));
    });

    describe("AND GIVEN a borrowMP with an amount of 5000 (250 charged in fees to accumulator) (4 days to go)", () => {
      const fourDaysToMaturity = nextPoolID - 86_400 * 4;
      beforeEach(async () => {
        borrowAmount = 5000;
        borrowFees = 250;
        await mockInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await marketEnv.moveInTime(fourDaysToMaturity);
        tx = await marketHarness
          .connect(laura)
          .borrowMaturityWithReturnValue(
            nextPoolID,
            parseUnits(borrowAmount.toString()),
            parseUnits((borrowAmount + borrowFees).toString()),
            laura.address,
            laura.address,
          );

        fixedBorrowPositions = await marketHarness.fixedBorrowPositions(nextPoolID, laura.address);
        returnValue = await marketHarness.returnValue();
        mp = await marketHarness.fixedPools(nextPoolID);
        fixedPoolState.earningsAccumulator = await marketHarness.smartPoolEarningsAccumulator();
        fixedPoolState.borrowFees = returnValue.sub(parseUnits(borrowAmount.toString()));
      });
      it("THEN borrowed is the just borrowed amount", async () => {
        expect(mp.borrowed).to.eq(parseUnits(borrowAmount.toString()));
      });
      it("THEN supplied is the just deposited amount", async () => {
        expect(mp.supplied).to.eq(parseUnits(depositAmount));
      });
      it("THEN unassignedEarnings are 0", async () => {
        expect(mp.unassignedEarnings).to.eq(0);
      });
      it("THEN lastAccrual is 4 days to maturity", async () => {
        expect(mp.lastAccrual).to.eq(fourDaysToMaturity);
      });
      it("THEN the fixedBorrowPositions is correctly updated", async () => {
        expect(fixedBorrowPositions[0]).to.be.eq(parseUnits(borrowAmount.toString()));
        expect(fixedBorrowPositions[1]).to.be.eq(parseUnits(borrowFees.toString()));
      });
      it("THEN the smartPoolEarningsAccumulator are 250", async () => {
        expect(await marketHarness.smartPoolEarningsAccumulator()).to.eq(
          parseUnits(borrowFees.toString()), // 5000 x 0,05 (5%)
        );
      });
      it("THEN the earningsSP returned are 0", async () => {
        const smartPoolAssets = await marketHarness.smartPoolAssets();
        await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
      });
      it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
        expect(returnValue).to.eq(parseUnits((borrowAmount + borrowFees).toString()));
      });

      describe("AND GIVEN another borrowMP call with an amount of 5000 (250 charged in fees to smartPoolEarningsAccumulator) (3 days to go)", () => {
        const threeDaysToMaturity = nextPoolID - 86_400 * 3;
        beforeEach(async () => {
          borrowAmount = 5000;
          borrowFees = 250;
          await marketEnv.moveInTime(threeDaysToMaturity);
          tx = await marketHarness
            .connect(laura)
            .borrowMaturityWithReturnValue(
              nextPoolID,
              parseUnits(borrowAmount.toString()),
              parseUnits((borrowAmount + borrowFees).toString()),
              laura.address,
              laura.address,
            );

          fixedBorrowPositions = await marketHarness.fixedBorrowPositions(nextPoolID, laura.address);
          returnValue = await marketHarness.returnValue();
          mp = await marketHarness.fixedPools(nextPoolID);
          fixedPoolState.earningsAccumulator = await marketHarness.smartPoolEarningsAccumulator();
          fixedPoolState.borrowFees = fixedPoolState.borrowFees.add(
            returnValue.sub(parseUnits(borrowAmount.toString())),
          );
          fixedPoolState.unassignedEarnings = parseUnits("0");
        });
        it("THEN borrowed is 2x the previously borrow amount", async () => {
          expect(mp.borrowed).to.eq(parseUnits((borrowAmount * 2).toString()));
        });
        it("THEN supplied is the one depositedAmount", async () => {
          expect(mp.supplied).to.eq(parseUnits(depositAmount.toString()));
        });
        it("THEN unassignedEarnings are 0", async () => {
          expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
        });
        it("THEN the lastAccrual is 3 days to maturity", async () => {
          expect(mp.lastAccrual).to.eq(threeDaysToMaturity);
        });
        it("THEN the borrow + fees are correctly added to the fixedBorrowPositions", async () => {
          expect(fixedBorrowPositions[0]).to.be.eq(parseUnits((borrowAmount * 2).toString()));
          expect(fixedBorrowPositions[1]).to.be.eq(parseUnits((borrowFees * 2).toString()));
        });
        it("THEN the smartPoolEarningsAccumulator are 500", async () => {
          // 250 + 250
          expect(await marketHarness.smartPoolEarningsAccumulator()).to.eq(parseUnits((borrowFees * 2).toString()));
        });
        it("THEN the earningsSP returned are 0", async () => {
          const smartPoolAssets = await marketHarness.smartPoolAssets();
          await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
        });
        it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
          expect(returnValue).to.eq(parseUnits((borrowAmount + borrowFees).toString()));
        });
        it("THEN the borrow fees are equal to all earnings distributed", async () => {
          expect(fixedPoolState.borrowFees).to.eq(marketEnv.getAllEarnings(fixedPoolState));
        });

        describe("AND GIVEN another borrowMP call with an amount of 5000 (250 charged in fees to unassigned) (2 days to go)", () => {
          const oneDayToMaturity = nextPoolID - 86_400;
          const twoDaysToMaturity = nextPoolID - 86_400 * 2;
          beforeEach(async () => {
            borrowAmount = 5000;
            borrowFees = 250;
            await marketEnv.moveInTime(twoDaysToMaturity);
            tx = await marketHarness
              .connect(laura)
              .borrowMaturityWithReturnValue(
                nextPoolID,
                parseUnits(borrowAmount.toString()),
                parseUnits((borrowAmount + borrowFees).toString()),
                laura.address,
                laura.address,
              );

            returnValue = await marketHarness.returnValue();
            mp = await marketHarness.fixedPools(nextPoolID);
            fixedPoolState.borrowFees = fixedPoolState.borrowFees.add(
              returnValue.sub(parseUnits(borrowAmount.toString())),
            );
            fixedPoolState.unassignedEarnings = fixedPoolState.unassignedEarnings.add(mp.unassignedEarnings);
          });
          it("THEN borrowed is 3x the borrowAmount", async () => {
            expect(mp.borrowed).to.eq(parseUnits((borrowAmount * 3).toString()));
          });
          it("THEN supplied is 1x depositAmount", async () => {
            expect(mp.supplied).to.eq(parseUnits(depositAmount));
          });
          it("THEN unassignedEarnings are 250", async () => {
            expect(mp.unassignedEarnings).to.eq(parseUnits(borrowFees.toString()));
          });
          it("THEN lastAccrual is 2 days to maturity", async () => {
            expect(mp.lastAccrual).to.eq(twoDaysToMaturity);
          });
          it("THEN the smartPoolEarningsAccumulator are still 500", async () => {
            expect(await marketHarness.smartPoolEarningsAccumulator()).to.eq(parseUnits((borrowFees * 2).toString()));
          });
          it("THEN the earningsSP returned are 0", async () => {
            const smartPoolAssets = await marketHarness.smartPoolAssets();
            await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
          });
          it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
            expect(returnValue).to.eq(parseUnits((borrowAmount + borrowFees).toString()));
          });
          it("THEN the borrow fees are equal to all earnings distributed", async () => {
            expect(fixedPoolState.borrowFees).to.eq(marketEnv.getAllEarnings(fixedPoolState));
          });

          describe("AND GIVEN a repayMP with an amount of 15750 (total EARLY repayment) (1 day to go)", () => {
            let mp: any;
            beforeEach(async () => {
              repayAmount = 15750;
              await marketEnv.moveInTime(oneDayToMaturity);
              tx = await marketHarness
                .connect(laura)
                .repayMaturityWithReturnValue(
                  nextPoolID,
                  parseUnits(repayAmount.toString()),
                  parseUnits(repayAmount.toString()),
                  laura.address,
                );

              fixedBorrowPositions = await marketHarness.fixedBorrowPositions(nextPoolID, laura.address);
              returnValue = await marketHarness.returnValue();
              fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(parseUnits("150"));
              mp = await marketHarness.fixedPools(nextPoolID);
            });

            it("THEN borrowed field is updated correctly and is 0", async () => {
              // debtCovered=17325*15750/17325=15750
              // principal of 15750 => 15000 (following ratio principal-fee of 15000 and 750)
              // borrowed original (15000) - 15000 = 0
              expect(mp.borrowed).to.be.eq(0);
            });

            it("THEN supplies are correctly updated", async () => {
              expect(mp.supplied).to.eq(
                parseUnits(depositAmount.toString()), // 10k
              );
            });
            it("THEN the debtCovered was equal to full repayAmount", async () => {
              // debtCovered=5775*5250/5775=5250
              await expect(tx)
                .to.emit(marketHarness, "RepayAtMaturity")
                .withArgs(nextPoolID, laura.address, laura.address, parseUnits("15625"), parseUnits("15750"));
            });
            it("THEN the fixedBorrowPositions position is 0", async () => {
              expect(fixedBorrowPositions[0]).to.be.eq(0);
              expect(fixedBorrowPositions[1]).to.be.eq(0);
            });
            it("THEN the smartPoolEarningsAccumulator are still 500", async () => {
              expect(await marketHarness.smartPoolEarningsAccumulator()).to.eq(parseUnits((borrowFees * 2).toString()));
            });
            it("THEN earningsSP returned 125", async () => {
              const smartPoolAssets = await marketHarness.smartPoolAssets();
              // unassignedEarnings were 250, then 1 day passed so earningsSP accrued half
              const earnings = parseUnits("125");
              await expect(tx)
                .to.emit(marketHarness, "SmartPoolEarningsAccrued")
                .withArgs(smartPoolAssets.sub(earnings), earnings);
            });
            it("THEN the actualRepayAmount returned is 15750 - 125", async () => {
              // Takes all the unassignedEarnings
              // first 500 were taken by the treasury
              // then 125 was accrued and earned by the SP
              // then the repay takes the rest as a discount
              expect(returnValue).to.eq(parseUnits((repayAmount - 125).toString()));
            });
          });

          describe("AND GIVEN a repayMP with an amount of 8000 (partial EARLY repayment) (1 day to go)", () => {
            let mp: any;
            beforeEach(async () => {
              repayAmount = 8000;
              await marketEnv.moveInTime(oneDayToMaturity);
              tx = await marketHarness
                .connect(laura)
                .repayMaturityWithReturnValue(
                  nextPoolID,
                  parseUnits(repayAmount.toString()),
                  parseUnits(repayAmount.toString()),
                  laura.address,
                );

              fixedBorrowPositions = await marketHarness.fixedBorrowPositions(nextPoolID, laura.address);
              returnValue = await marketHarness.returnValue();
              fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(parseUnits("125"));
              mp = await marketHarness.fixedPools(nextPoolID);
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
                parseUnits(depositAmount.toString()), // 10k
              );
            });
            it("THEN the debtCovered was equal to full repayAmount (8000)", async () => {
              await expect(tx)
                .to.emit(marketHarness, "RepayAtMaturity")
                .withArgs(nextPoolID, laura.address, laura.address, parseUnits("7875"), parseUnits("8000"));
            });
            it("THEN the fixedBorrowPositions is correctly updated (principal + fees = 7750)", async () => {
              expect(fixedBorrowPositions[0]).to.be.gt(parseUnits("7380"));
              expect(fixedBorrowPositions[0]).to.be.lt(parseUnits("7381"));
              expect(fixedBorrowPositions[1]).to.be.gt(parseUnits("369"));
              expect(fixedBorrowPositions[1]).to.be.lt(parseUnits("370"));
            });
            it("THEN the smartPoolEarningsAccumulator are still 500", async () => {
              expect(await marketHarness.smartPoolEarningsAccumulator()).to.eq(parseUnits((borrowFees * 2).toString()));
            });
            it("THEN earningsSP returned 125", async () => {
              const smartPoolAssets = await marketHarness.smartPoolAssets();
              const earnings = parseUnits("125");
              // unassignedEarnings were 250, then 1 day passed so earningsSP accrued half
              await expect(tx)
                .to.emit(marketHarness, "SmartPoolEarningsAccrued")
                .withArgs(smartPoolAssets.sub(earnings), earnings);
            });
            it("THEN the actualRepayAmount returned is 8000 - 125", async () => {
              // Takes all the unassignedEarnings
              // first 500 were taken by the treasury
              // then 125 was accrued and earned by the SP
              // then the repay takes the rest as a discount
              expect(returnValue).to.eq(parseUnits((repayAmount - 125).toString()));
            });
          });

          describe("AND GIVEN a repayMP at maturity(-1 DAY) with an amount of 15750 but asking a 126 discount (total EARLY repayment) ", () => {
            let tx: any;
            beforeEach(async () => {
              await marketEnv.moveInTime(oneDayToMaturity);
              repayAmount = 15750;
              tx = marketHarness
                .connect(laura)
                .repayMaturityWithReturnValue(
                  nextPoolID,
                  parseUnits(repayAmount.toString()),
                  parseUnits((repayAmount - 126).toString()),
                  laura.address,
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
              await marketHarness.setFreePenaltyRate(parseUnits("0.1").div(86_400));
              await marketEnv.moveInTime(nextPoolID + 86_400);
              repayAmount = 17325;
              tx = await marketHarness
                .connect(laura)
                .repayMaturityWithReturnValue(
                  nextPoolID,
                  parseUnits(repayAmount.toString()),
                  parseUnits(repayAmount.toString()),
                  laura.address,
                );

              fixedBorrowPositions = await marketHarness.fixedBorrowPositions(nextPoolID, laura.address);
              returnValue = await marketHarness.returnValue();
              fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(parseUnits("250"));
              mp = await marketHarness.fixedPools(nextPoolID);
            });

            it("THEN borrowed field is updated correctly and is 0", async () => {
              // debtCovered=17325*15750/17325=15750
              // principal of 15750 => 15000 (following ratio principal-fee of 15000 and 750)
              // borrowed original (15000) - 15000 = 0
              expect(mp.borrowed).to.be.eq(0);
            });

            it("THEN supplies are correctly updated", async () => {
              expect(mp.supplied).to.eq(
                parseUnits(depositAmount.toString()), // 10k
              );
            });
            it("THEN the debtCovered was equal to full repayAmount", async () => {
              // debtCovered=5775*5250/5775=5250
              await expect(tx)
                .to.emit(marketHarness, "RepayAtMaturity")
                .withArgs(nextPoolID, laura.address, laura.address, "17324999999999445600000", parseUnits("15750"));
            });
            it("THEN earningsSP receive no % of penalties", async () => {
              const smartPoolAssets = await marketHarness.smartPoolAssets();
              // 250 (previous unassigned earnings)
              const earnings = parseUnits("250");
              await expect(tx)
                .to.emit(marketHarness, "SmartPoolEarningsAccrued")
                .withArgs(smartPoolAssets.sub(earnings), earnings);
            });
            it("THEN the smartPoolEarningsAccumulator receives all penalties", async () => {
              // 17325 - 15750 = 1575
              // + 500 (previous accumulated earnings)
              expect(await marketHarness.smartPoolEarningsAccumulator()).to.gt(parseUnits("2074"));
              expect(await marketHarness.smartPoolEarningsAccumulator()).to.lt(parseUnits("2075"));
            });
            it("THEN the fixedBorrowPositions position is 0", async () => {
              expect(fixedBorrowPositions[0]).to.be.eq(0);
              expect(fixedBorrowPositions[1]).to.be.eq(0);
            });
            it("THEN the actualRepayAmount returned is almost 17325", async () => {
              expect(returnValue).to.lt(parseUnits(repayAmount.toString()));
              expect(returnValue).to.gt(parseUnits((repayAmount - 0.1).toString()));
            });

            afterEach(async () => {
              await marketHarness.setFreePenaltyRate(0);
            });
          });

          describe("AND GIVEN another depositMP with an amount of 5000 (half of 250 unassigned earnings earned) (1 day to go)", () => {
            beforeEach(async () => {
              depositAmount = 5000;

              await marketEnv.moveInTime(oneDayToMaturity);
              tx = await marketHarness
                .connect(laura)
                .depositMaturityWithReturnValue(
                  nextPoolID,
                  parseUnits(depositAmount.toString()),
                  parseUnits(depositAmount.toString()),
                  laura.address,
                );

              returnValue = await marketHarness.returnValue();
              mp = await marketHarness.fixedPools(nextPoolID);
              fixedPoolState.earningsAccumulator = await marketHarness.smartPoolEarningsAccumulator();
              fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(parseUnits("125"));
              fixedPoolState.earningsMP = returnValue.sub(parseUnits(depositAmount.toString()));
              fixedPoolState.unassignedEarnings = parseUnits("0");
              fixedDepositPositions = await marketHarness.fixedDepositPositions(nextPoolID, laura.address);
            });
            it("THEN borrowed is 3x borrowAmount", async () => {
              expect(mp.borrowed).to.eq(
                parseUnits((borrowAmount * 3).toString()), // 3 borrows of 5k were made
              );
            });
            it("THEN supplied is 15000", async () => {
              expect(mp.supplied).to.eq(
                parseUnits((depositAmount + 10000).toString()), // 1 deposits of 5k + 1 deposit of 10k
              );
            });
            it("THEN unassignedEarnings are 0", async () => {
              expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
            });
            it("THEN lastAccrual is 1 day to maturity", async () => {
              expect(mp.lastAccrual).to.eq(oneDayToMaturity);
            });
            it("THEN the fixedDepositPositions is correctly updated", async () => {
              expect(fixedDepositPositions[0]).to.be.eq(parseUnits((depositAmount + 10000).toString()));
              expect(fixedDepositPositions[1]).to.be.eq(parseUnits((250 / 2).toString()));
            });
            it("THEN the earningsSP returned are 125", async () => {
              const smartPoolAssets = await marketHarness.smartPoolAssets();
              // 250 (previous unassigned) / 2 days
              const earnings = parseUnits((250 / 2).toString());
              await expect(tx)
                .to.emit(marketHarness, "SmartPoolEarningsAccrued")
                .withArgs(smartPoolAssets.sub(earnings), earnings);
            });
            it("THEN the smartPoolEarningsAccumulator are still 500", async () => {
              expect(await marketHarness.smartPoolEarningsAccumulator()).to.eq(parseUnits((borrowFees * 2).toString()));
            });
            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValue).to.eq(parseUnits((depositAmount + 250 / 2).toString()));
            });
            it("THEN the borrow fees are equal to all earnings distributed", async () => {
              expect(fixedPoolState.borrowFees).to.eq(marketEnv.getAllEarnings(fixedPoolState));
            });
          });

          describe("AND GIVEN another depositMP with an amount of 5000 and with a backupFeeRate of 10% (125 - (125 * 0.1) fees earned)", () => {
            beforeEach(async () => {
              depositAmount = 5000;

              await marketHarness.setBackupFeeRate(parseUnits("0.1")); // 10% fees charged from the mp depositor yield to the sp earnings
              await marketEnv.moveInTime(oneDayToMaturity);
              tx = await marketHarness
                .connect(laura)
                .depositMaturityWithReturnValue(
                  nextPoolID,
                  parseUnits(depositAmount.toString()),
                  parseUnits(depositAmount.toString()),
                  laura.address,
                );

              returnValue = await marketHarness.returnValue();
              mp = await marketHarness.fixedPools(nextPoolID);
              fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(parseUnits("125"));
              fixedPoolState.earningsAccumulator = await marketHarness.smartPoolEarningsAccumulator();
              fixedPoolState.earningsMP = returnValue.sub(parseUnits(depositAmount.toString()));
              fixedPoolState.unassignedEarnings = parseUnits("0");
            });

            it("THEN borrowed is 3x borrowAmount", async () => {
              expect(mp.borrowed).to.eq(
                parseUnits((borrowAmount * 3).toString()), // 3 borrows of 5k were made
              );
            });
            it("THEN supplied is 15000", async () => {
              expect(mp.supplied).to.eq(
                parseUnits((depositAmount + 10000).toString()), // 1 deposits of 5k + 1 deposit of 10k
              );
            });
            it("THEN unassignedEarnings are 0", async () => {
              expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
            });
            it("THEN lastAccrual is 1 day to maturity", async () => {
              expect(mp.lastAccrual).to.eq(oneDayToMaturity);
            });
            it("THEN the earningsSP returned are just 125", async () => {
              const smartPoolAssets = await marketHarness.smartPoolAssets();
              // 250 (previous unassigned) / 2 days
              const earnings = parseUnits((250 / 2).toString());
              await expect(tx)
                .to.emit(marketHarness, "SmartPoolEarningsAccrued")
                .withArgs(smartPoolAssets.sub(earnings), earnings);
            });
            it("THEN the smartPoolEarningsAccumulator are 500 + 12.5", async () => {
              expect(await marketHarness.smartPoolEarningsAccumulator()).to.eq(
                parseUnits((borrowFees * 2 + 12.5).toString()),
              );
            });
            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValue).to.eq(parseUnits((depositAmount + 250 / 2 - 12.5).toString()));
            });
            it("THEN the borrow fees are equal to all earnings distributed", async () => {
              expect(fixedPoolState.borrowFees).to.eq(marketEnv.getAllEarnings(fixedPoolState));
            });
          });

          describe("AND GIVEN another depositMP with an exorbitant amount of 100M (all fees earned - same as depositing only 5k)", () => {
            beforeEach(async () => {
              depositAmount = 100000000;

              await marketEnv.moveInTime(oneDayToMaturity);
              await marketHarness
                .connect(laura)
                .depositMaturityWithReturnValue(
                  nextPoolID,
                  parseUnits(depositAmount.toString()),
                  parseUnits(depositAmount.toString()),
                  laura.address,
                );

              returnValue = await marketHarness.returnValue();
              mp = await marketHarness.fixedPools(nextPoolID);
            });

            it("THEN borrowed is 3x borrowAmount", async () => {
              expect(mp.borrowed).to.eq(
                parseUnits((borrowAmount * 3).toString()), // 3 borrows of 5k where made
              );
            });
            it("THEN supplied is depositAmount + 10000 (10k are previous deposited amount)", async () => {
              expect(mp.supplied).to.eq(
                parseUnits((depositAmount + 10000).toString()), // 10000 = previous deposited amount
              );
            });
            it("THEN unassignedEarnings are 0", async () => {
              expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
            });
            it("THEN lastAccrual is 1 day before maturity", async () => {
              expect(mp.lastAccrual).to.eq(oneDayToMaturity);
            });
            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValue).to.eq(parseUnits((depositAmount + 125).toString()));
            });

            describe("AND GIVEN an EARLY repayMP with an amount of 5250 (12 hours to maturity)", () => {
              const twelveHoursToMaturity = nextPoolID - 3_600 * 12;

              beforeEach(async () => {
                repayAmount = 5250;

                await marketEnv.moveInTime(twelveHoursToMaturity);
                tx = await marketHarness
                  .connect(laura)
                  .repayMaturityWithReturnValue(
                    nextPoolID,
                    parseUnits(repayAmount.toString()),
                    parseUnits(repayAmount.toString()),
                    laura.address,
                  );

                mp = await marketHarness.fixedPools(nextPoolID);
              });

              it("THEN borrowed is (borrowAmount(principal) * 3 - repayAmount(principal)) = 10K", async () => {
                expect(mp.borrowed).to.eq(parseUnits("10000"));
              });
              it("THEN supplied is 100M + 10k", async () => {
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()), // 100M + 10k deposit
                );
              });
              it("THEN the smartPoolEarningsAccumulator are still 500", async () => {
                expect(await marketHarness.smartPoolEarningsAccumulator()).to.eq(
                  parseUnits((borrowFees * 2).toString()),
                );
              });
              it("THEN unassignedEarnings are still 0", async () => {
                expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                const smartPoolAssets = await marketHarness.smartPoolAssets();
                await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
              });
              it("THEN lastAccrual is 12 hours before maturity", async () => {
                expect(mp.lastAccrual).to.eq(twelveHoursToMaturity);
              });
              it("THEN the debtCovered was the full repayAmount", async () => {
                await expect(tx)
                  .to.emit(marketHarness, "RepayAtMaturity")
                  .withArgs(
                    nextPoolID,
                    laura.address,
                    laura.address,
                    parseUnits(repayAmount.toString()),
                    parseUnits(repayAmount.toString()),
                  );
              });
            });

            describe("AND GIVEN a total EARLY repayMP with an amount of 15750 (all debt)", () => {
              const twelveHoursToMaturity = nextPoolID - 3_600 * 12;

              beforeEach(async () => {
                repayAmount = 15750;

                await marketEnv.moveInTime(twelveHoursToMaturity);
                tx = await marketHarness
                  .connect(laura)
                  .repayMaturityWithReturnValue(
                    nextPoolID,
                    parseUnits(repayAmount.toString()),
                    parseUnits(repayAmount.toString()),
                    laura.address,
                  );

                mp = await marketHarness.fixedPools(nextPoolID);
              });
              it("THEN unassignedEarnings are still 0", async () => {
                expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
              });
              it("THEN the debtCovered was the full amount repaid", async () => {
                await expect(tx)
                  .to.emit(marketHarness, "RepayAtMaturity")
                  .withArgs(
                    nextPoolID,
                    laura.address,
                    laura.address,
                    parseUnits(repayAmount.toString()),
                    parseUnits(repayAmount.toString()),
                  );
              });
              it("THEN the earningsSP returned are 0", async () => {
                const smartPoolAssets = await marketHarness.smartPoolAssets();
                await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
              });
            });

            describe("AND GIVEN a total repayMP at maturity with an amount of 15750 (all debt)", () => {
              beforeEach(async () => {
                repayAmount = 15750;

                await marketEnv.moveInTime(nextPoolID);
                tx = await marketHarness
                  .connect(laura)
                  .repayMaturityWithReturnValue(
                    nextPoolID,
                    parseUnits(repayAmount.toString()),
                    parseUnits(repayAmount.toString()),
                    laura.address,
                  );

                mp = await marketHarness.fixedPools(nextPoolID);
              });
              it("THEN the maturity pool state is correctly updated", async () => {
                expect(mp.borrowed).to.eq(parseUnits("0"));
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()), // 1M + 10k deposit
                );
              });
              it("THEN the debtCovered was equal to full repayAmount", async () => {
                await expect(tx)
                  .to.emit(marketHarness, "RepayAtMaturity")
                  .withArgs(
                    nextPoolID,
                    laura.address,
                    laura.address,
                    parseUnits(repayAmount.toString()),
                    parseUnits(repayAmount.toString()),
                  );
              });
              it("THEN unassignedEarnings are still 0", async () => {
                expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                const smartPoolAssets = await marketHarness.smartPoolAssets();
                await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
              });
              describe("AND GIVEN a partial withdrawMP of 50M", () => {
                beforeEach(async () => {
                  withdrawAmount = 50000000;

                  tx = await marketHarness
                    .connect(laura)
                    .withdrawMaturityWithReturnValue(
                      nextPoolID,
                      parseUnits(withdrawAmount.toString()),
                      parseUnits(withdrawAmount.toString()),
                      laura.address,
                      laura.address,
                    );

                  mp = await marketHarness.fixedPools(nextPoolID);
                  returnValue = await marketHarness.returnValue();
                  fixedDepositPositions = await marketHarness.fixedDepositPositions(nextPoolID, laura.address);
                });
                it("THEN the maturity pool state is correctly updated", async () => {
                  expect(mp.borrowed).to.eq(parseUnits("0"));
                  expect(mp.supplied).to.be.eq(fixedDepositPositions[0]);
                });
                it("THEN unassignedEarnings are still 0", async () => {
                  expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
                });
                it("THEN the earningsSP returned are 0", async () => {
                  const smartPoolAssets = await marketHarness.smartPoolAssets();
                  await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
                });
                it("THEN the fixedDepositPositions is correctly updated", async () => {
                  // all supplied + earned of laura is 100010125
                  // if we withdraw 50M, then her position is scaled
                  const totalFeeEarned = fixedDepositPositions[1].add(
                    fixedDepositPositions[0].sub(parseUnits("50010000")),
                  );

                  expect(fixedDepositPositions[0]).to.be.lt(parseUnits("50010062.5"));
                  expect(fixedDepositPositions[0]).to.be.gt(parseUnits("50010062.49"));
                  expect(fixedDepositPositions[1]).to.be.lt(parseUnits("62.51"));
                  expect(fixedDepositPositions[1]).to.be.gt(parseUnits("62.5"));
                  expect(totalFeeEarned).to.eq(parseUnits("125"));
                });
                it("THEN the redeemAmountDiscounted returned is equal to the amount withdrawn", async () => {
                  expect(returnValue).to.eq(parseUnits(withdrawAmount.toString()));
                });
                it("THEN the withdrawAmount + remaining fees + supplied that still remains in the pool equals initial total deposit", async () => {
                  const fixedDepositPositions = await marketHarness.fixedDepositPositions(nextPoolID, laura.address);

                  expect(returnValue.add(mp.supplied).add(fixedDepositPositions[1])).to.eq(parseUnits("100010125"));
                });
              });
              describe("AND GIVEN a partial withdrawMP of half amount deposited + half earned fees", () => {
                beforeEach(async () => {
                  withdrawAmount = 50005062.5; // 5k + 50M + 62.5 earned fees

                  tx = await marketHarness
                    .connect(laura)
                    .withdrawMaturityWithReturnValue(
                      nextPoolID,
                      parseUnits(withdrawAmount.toString()),
                      parseUnits(withdrawAmount.toString()),
                      laura.address,
                      laura.address,
                    );

                  mp = await marketHarness.fixedPools(nextPoolID);
                  returnValue = await marketHarness.returnValue();
                });
                it("THEN the maturity pool state is correctly updated", async () => {
                  expect(mp.borrowed).to.eq(parseUnits("0"));
                  expect(mp.supplied).to.eq(parseUnits("50005000"));
                });
                it("THEN unassignedEarnings are still 0", async () => {
                  expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
                });
                it("THEN the earningsSP returned are 0", async () => {
                  const smartPoolAssets = await marketHarness.smartPoolAssets();
                  await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
                });
                it("THEN the redeemAmountDiscounted returned is equal to the amount withdrawn", async () => {
                  expect(returnValue).to.eq(parseUnits(withdrawAmount.toString()));
                });
              });
              describe("AND GIVEN a total withdrawMP of the total amount deposited + earned fees", () => {
                beforeEach(async () => {
                  withdrawAmount = 100010125; // 10k + 100M + 125 earned fees

                  tx = await marketHarness
                    .connect(laura)
                    .withdrawMaturityWithReturnValue(
                      nextPoolID,
                      parseUnits(withdrawAmount.toString()),
                      parseUnits(withdrawAmount.toString()),
                      laura.address,
                      laura.address,
                    );

                  mp = await marketHarness.fixedPools(nextPoolID);
                  returnValue = await marketHarness.returnValue();
                });
                it("THEN the maturity pool state is correctly updated", async () => {
                  expect(mp.borrowed).to.eq(parseUnits("0"));
                  expect(mp.supplied).to.eq(parseUnits("0"));
                });
                it("THEN unassignedEarnings are still 0", async () => {
                  expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
                });
                it("THEN the earningsSP returned are 0", async () => {
                  const smartPoolAssets = await marketHarness.smartPoolAssets();
                  await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
                });
                it("THEN the redeemAmountDiscounted returned is equal to all amount withdrawn", async () => {
                  expect(returnValue).to.eq(parseUnits(withdrawAmount.toString()));
                });
              });
            });

            describe("AND GIVEN a partial repayMP at maturity(+1 DAY) with an amount of 8000 (partial late repayment)", () => {
              let mp: any;
              beforeEach(async () => {
                await marketHarness.setFreePenaltyRate(parseUnits("0.1").div(86_400));

                await marketEnv.moveInTime(nextPoolID + 86_400);
                repayAmount = 8000;
                tx = await marketHarness
                  .connect(laura)
                  .repayMaturityWithReturnValue(
                    nextPoolID,
                    parseUnits(repayAmount.toString()),
                    parseUnits("9000"),
                    laura.address,
                  );
                // returnValue = await marketHarness.returnValue();
                mp = await marketHarness.fixedPools(nextPoolID);
              });

              it("THEN borrowed field is updated correctly (~8073)", async () => {
                expect(mp.borrowed).to.be.gt(parseUnits("7380.95"));
                expect(mp.borrowed).to.be.lt(parseUnits("7380.96"));
              });

              it("THEN supplies are correctly updated", async () => {
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()), // 1M + 10k deposit
                );
              });
              it("THEN the debtCovered was equal to full repayAmount", async () => {
                await expect(tx)
                  .to.emit(marketHarness, "RepayAtMaturity")
                  .withArgs(nextPoolID, laura.address, laura.address, "8799999999999718400000", parseUnits("8000"));
              });
              it("THEN smartPoolEarningsAccumulator receives the 10% of penalties", async () => {
                expect(await marketHarness.smartPoolEarningsAccumulator()).to.gt(parseUnits("1299.999"));
                expect(await marketHarness.smartPoolEarningsAccumulator()).to.lt(parseUnits("1300"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                const smartPoolAssets = await marketHarness.smartPoolAssets();
                await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
              });

              afterEach(async () => {
                await marketHarness.setFreePenaltyRate(0);
              });
            });

            describe("AND GIVEN a repayMP at maturity(+1 DAY) with an amount of 15750*1.1=17325 (total late repayment)", () => {
              let mp: any;
              beforeEach(async () => {
                await marketHarness.setFreePenaltyRate(parseUnits("0.1").div(86_400));

                await marketEnv.moveInTime(nextPoolID + 86_400);
                repayAmount = 17325;
                tx = await marketHarness
                  .connect(laura)
                  .repayMaturityWithReturnValue(
                    nextPoolID,
                    parseUnits(repayAmount.toString()),
                    parseUnits(repayAmount.toString()),
                    laura.address,
                  );
                returnValue = await marketHarness.returnValue();
                mp = await marketHarness.fixedPools(nextPoolID);
              });

              it("THEN borrowed field is updated correctly and is 0", async () => {
                // debtCovered=17325*15750/17325=15750
                // principal of 15750 => 15000 (following ratio principal-fee of 15000 and 750)
                // borrowed original (15000) - 15000 = 0
                expect(mp.borrowed).to.be.eq(0);
              });

              it("THEN supplies are correctly updated", async () => {
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()), // 1M + 10k deposit
                );
              });
              it("THEN the debtCovered was equal to full repayAmount", async () => {
                // debtCovered=17325*15750/17325=15750
                await expect(tx)
                  .to.emit(marketHarness, "RepayAtMaturity")
                  .withArgs(nextPoolID, laura.address, laura.address, "17324999999999445600000", parseUnits("15750"));
              });
              it("THEN smartPoolEarningsAccumulator receives 10% of penalties", async () => {
                // 17325 - 15750 = 1575 (10% of the debt)
                // + 500 previous earnings
                expect(await marketHarness.smartPoolEarningsAccumulator()).to.gt(parseUnits("2074"));
                expect(await marketHarness.smartPoolEarningsAccumulator()).to.lt(parseUnits("2075"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                const smartPoolAssets = await marketHarness.smartPoolAssets();
                await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
              });
              it("THEN the actualRepayAmount returned is almost 17325", async () => {
                expect(returnValue).to.lt(parseUnits(repayAmount.toString()));
                expect(returnValue).to.gt(parseUnits((repayAmount - 0.1).toString()));
              });
            });

            describe("AND GIVEN a repayMP at maturity(+1 DAY) with an amount of 2000 on a debt 15750*0.1=17325 (way more money late repayment)", () => {
              let mp: any;
              beforeEach(async () => {
                await marketHarness.setFreePenaltyRate(parseUnits("0.1").div(86_400));

                await marketEnv.moveInTime(nextPoolID + 86_400);
                repayAmount = 20000;
                tx = await marketHarness
                  .connect(laura)
                  .repayMaturityWithReturnValue(
                    nextPoolID,
                    parseUnits(repayAmount.toString()),
                    parseUnits(repayAmount.toString()),
                    laura.address,
                  );
                returnValue = await marketHarness.returnValue();
                mp = await marketHarness.fixedPools(nextPoolID);
              });

              it("THEN borrowed field is updated correctly and is 0", async () => {
                // debtCovered=17325*15750/17325=15750
                // principal of 15750 => 15000 (following ratio principal-fee of 15000 and 750)
                // borrowed original (15000) - 15000 = 0
                expect(mp.borrowed).to.be.eq(0);
              });

              it("THEN supplies are correctly updated", async () => {
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()), // 1M + 10k deposit
                );
              });
              it("THEN the debtCovered was equal to full repayAmount", async () => {
                // debtCovered=17325*15750/17325=15750
                await expect(tx)
                  .to.emit(marketHarness, "RepayAtMaturity")
                  .withArgs(nextPoolID, laura.address, laura.address, "17324999999999445600000", parseUnits("15750"));
              });
              it("THEN smartPoolEarningsAccumulator receive the 10% of penalties", async () => {
                // 17325 - 15750 = 1575 (10% of the debt)
                // + 500 previous earnings
                expect(await marketHarness.smartPoolEarningsAccumulator()).to.gt(parseUnits("2074"));
                expect(await marketHarness.smartPoolEarningsAccumulator()).to.lt(parseUnits("2075"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                const smartPoolAssets = await marketHarness.smartPoolAssets();
                await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
              });
              it("THEN the actualRepayAmount returned is ~= 17325 (paid 20000 on a 17325 debt)", async () => {
                expect(returnValue).to.be.gt(parseUnits("17324.9"));
                expect(returnValue).to.be.lt(parseUnits("17325"));
              });
            });
          });
        });
      });
    });
  });

  describe("Assignment of earnings over time", () => {
    describe("GIVEN a borrowMP of 10000 (600 fees owed by user) - 24 days to maturity", () => {
      let tx: ContractTransaction;
      let returnValue: any;
      let mp: any;
      const twentyFourDaysToMaturity = nextPoolID - 86_400 * 24;
      const twentyDaysToMaturity = nextPoolID - 86_400 * 20;
      const sixteenDaysToMaturity = nextPoolID - 86_400 * 16;
      const twelveDaysToMaturity = nextPoolID - 86_400 * 12;
      const eightDaysToMaturity = nextPoolID - 86_400 * 8;
      const fourDaysToMaturity = nextPoolID - 86_400 * 4;

      beforeEach(async () => {
        marketEnv.switchWallet(laura);
        await mockInterestRateModel.setBorrowRate(parseUnits("0.06"));
        await marketEnv.moveInTime(twentyFourDaysToMaturity);
        await marketHarness
          .connect(laura)
          .borrowMaturityWithReturnValue(
            nextPoolID,
            parseUnits("10000"),
            parseUnits("10600"),
            laura.address,
            laura.address,
          );
      });
      describe("AND GIVEN a depositMP of 1000 (50 fees earned by user) - 20 days to maturity", () => {
        beforeEach(async () => {
          await marketEnv.moveInTime(twentyDaysToMaturity);
          tx = await marketHarness
            .connect(laura)
            .depositMaturityWithReturnValue(nextPoolID, parseUnits("1000"), parseUnits("1000"), laura.address);
          mp = await marketHarness.fixedPools(nextPoolID);
          returnValue = await marketHarness.returnValue();
        });
        it("THEN unassignedEarnings should be 360", () => {
          expect(mp.unassignedEarnings).to.eq(parseUnits("450")); // 600 - 100 (earningsSP) - 50 (earnings MP depositor)
        });
        it("THEN the earningsSP returned are 100", async () => {
          const smartPoolAssets = await marketHarness.smartPoolAssets();
          // 1 day passed
          const earnings = parseUnits("100");
          await expect(tx)
            .to.emit(marketHarness, "SmartPoolEarningsAccrued")
            .withArgs(smartPoolAssets.sub(earnings), earnings);
        });
        it("THEN the currentTotalDeposit returned is 1050", async () => {
          expect(returnValue).to.eq(parseUnits("1050"));
        });
        describe("AND GIVEN a withdraw of 1050 - 16 days to maturity", () => {
          beforeEach(async () => {
            await mockInterestRateModel.setBorrowRate(parseUnits("0.05"));
            await marketEnv.moveInTime(sixteenDaysToMaturity);
            tx = await marketHarness
              .connect(laura)
              .withdrawMaturityWithReturnValue(
                nextPoolID,
                parseUnits("1050"),
                parseUnits("1000"),
                laura.address,
                laura.address,
              );
            mp = await marketHarness.fixedPools(nextPoolID);
          });
          it("THEN unassignedEarnings should be 410", () => {
            expect(mp.unassignedEarnings).to.eq(parseUnits("410")); // 450 - 90 + 50
          });
          it("THEN the earningsSP returned are 90", async () => {
            const smartPoolAssets = await marketHarness.smartPoolAssets();
            const earnings = parseUnits("90"); // 450 / 5
            await expect(tx)
              .to.emit(marketHarness, "SmartPoolEarningsAccrued")
              .withArgs(smartPoolAssets.sub(earnings), earnings);
          });
          describe("AND GIVEN another borrowMP of 10000 (601.5 fees owed by user) - 12 days to maturity", () => {
            beforeEach(async () => {
              await mockInterestRateModel.setBorrowRate(parseUnits("0.06015"));
              await marketEnv.moveInTime(twelveDaysToMaturity);
              tx = await marketHarness
                .connect(laura)
                .borrowMaturityWithReturnValue(
                  nextPoolID,
                  parseUnits("10000"),
                  parseUnits("10610"),
                  laura.address,
                  laura.address,
                );
              mp = await marketHarness.fixedPools(nextPoolID);
              returnValue = await marketHarness.returnValue();
            });
            it("THEN unassignedEarnings should be 909", () => {
              expect(mp.unassignedEarnings).to.eq(parseUnits("909")); // 410 - 102.5 (410 / 4) + 601.5
            });
            it("THEN the earningsSP returned are 102.5", async () => {
              const smartPoolAssets = await marketHarness.smartPoolAssets();
              const earnings = parseUnits("102.5"); // (410 / 4)
              await expect(tx)
                .to.emit(marketHarness, "SmartPoolEarningsAccrued")
                .withArgs(smartPoolAssets.sub(earnings), earnings);
            });
            it("THEN the totalOwedNewBorrow returned is 10601.5", async () => {
              expect(returnValue).to.eq(parseUnits("10601.5"));
            });
            describe("AND GIVEN a repayMP of 10600.75 (half of borrowed) - 8 days to maturity", () => {
              beforeEach(async () => {
                await marketEnv.moveInTime(eightDaysToMaturity);
                tx = await marketHarness
                  .connect(laura)
                  .repayMaturityWithReturnValue(
                    nextPoolID,
                    parseUnits("10600.75"),
                    parseUnits("10600.75"),
                    laura.address,
                  );
                mp = await marketHarness.fixedPools(nextPoolID);
                returnValue = await marketHarness.returnValue();
              });
              it("THEN unassignedEarnings should be 303", () => {
                expect(mp.unassignedEarnings).to.eq(parseUnits("303"));
              });
              it("THEN the earningsSP returned are 303", async () => {
                const smartPoolAssets = await marketHarness.smartPoolAssets();
                const earnings = parseUnits("303"); // 909 / 3
                await expect(tx)
                  .to.emit(marketHarness, "SmartPoolEarningsAccrued")
                  .withArgs(smartPoolAssets.sub(earnings), earnings);
              });
              it("THEN the actualRepayAmount returned is 10600.75 - 303", async () => {
                expect(returnValue).to.eq(
                  parseUnits("10297.75"), // 10600.75 - (909 - 303) / 2
                );
              });
              it("THEN the debtCovered returned is 10600.75", async () => {
                await expect(tx)
                  .to.emit(marketHarness, "RepayAtMaturity")
                  .withArgs(nextPoolID, laura.address, laura.address, parseUnits("10297.75"), parseUnits("10600.75"));
              });
              describe("AND GIVEN a repayMP of the other half (10600.75) - 4 days to maturity", () => {
                beforeEach(async () => {
                  await marketEnv.moveInTime(fourDaysToMaturity);
                  tx = await marketHarness
                    .connect(laura)
                    .repayMaturityWithReturnValue(
                      nextPoolID,
                      parseUnits("10600.75"),
                      parseUnits("10600.75"),
                      laura.address,
                    );
                  mp = await marketHarness.fixedPools(nextPoolID);
                  returnValue = await marketHarness.returnValue();
                });
                it("THEN unassignedEarnings should be 0", () => {
                  expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
                });
                it("THEN the earningsSP returned are 151.5", async () => {
                  const smartPoolAssets = await marketHarness.smartPoolAssets();
                  const earnings = parseUnits("151.5"); // 303 / 2
                  await expect(tx)
                    .to.emit(marketHarness, "SmartPoolEarningsAccrued")
                    .withArgs(smartPoolAssets.sub(earnings), earnings);
                });
                it("THEN the actualRepayAmount returned is 10600.75 - 151.5", async () => {
                  expect(returnValue).to.eq(parseUnits("10449.25"));
                });
                it("THEN the debtCovered returned is 10600.75", async () => {
                  await expect(tx)
                    .to.emit(marketHarness, "RepayAtMaturity")
                    .withArgs(nextPoolID, laura.address, laura.address, parseUnits("10449.25"), parseUnits("10600.75"));
                });
              });
            });
          });
        });
      });
    });
  });

  describe("Early Withdrawal / Early Repayment", () => {
    let tx: ContractTransaction;
    let returnValue: any;
    let mp: any;
    let borrowAmount: number;
    let fixedPoolState: FixedPoolState;
    const fiveDaysToMaturity = nextPoolID - 86_400 * 5;
    const fourDaysToMaturity = nextPoolID - 86_400 * 4;
    const threeDaysToMaturity = nextPoolID - 86_400 * 3;

    beforeEach(async () => {
      fixedPoolState = {
        borrowFees: parseUnits("0"),
        unassignedEarnings: parseUnits("0"),
        earningsAccumulator: parseUnits("0"),
        earningsSP: parseUnits("0"),
        earningsMP: parseUnits("0"),
        earningsDiscounted: parseUnits("0"),
      };
    });

    describe("GIVEN an empty SP AND a deposit of 100", () => {
      beforeEach(async () => {
        await marketHarness
          .connect(laura)
          .depositMaturityWithReturnValue(nextPoolID, parseUnits("100"), parseUnits("100"), laura.address);
      });

      it("THEN it should not revert when trying to withdraw early previous 100 deposited", async () => {
        marketEnv.switchWallet(laura);
        await expect(
          marketHarness
            .connect(laura)
            .withdrawMaturityWithReturnValue(
              nextPoolID,
              parseUnits("100"),
              parseUnits("90"),
              laura.address,
              laura.address,
            ),
        ).to.not.be.reverted;
      });
    });

    describe("GIVEN a borrowMP of 10000 (500 fees owed by user)", () => {
      beforeEach(async () => {
        borrowAmount = 10000;
        marketEnv.switchWallet(laura);
        await mockInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await marketEnv.moveInTime(fiveDaysToMaturity);
        await marketHarness
          .connect(laura)
          .borrowMaturityWithReturnValue(
            nextPoolID,
            parseUnits(borrowAmount.toString()),
            parseUnits((borrowAmount * 1.05).toString()),
            laura.address,
            laura.address,
          );

        mp = await marketHarness.fixedPools(nextPoolID);
        returnValue = await marketHarness.returnValue();
        fixedPoolState.borrowFees = returnValue.sub(parseUnits(borrowAmount.toString()));
      });

      it("THEN all unassignedEarnings should be 500", () => {
        expect(mp.unassignedEarnings).to.eq(parseUnits("500"));
      });

      describe("WHEN an early repayment of 5250", () => {
        beforeEach(async () => {
          await marketEnv.moveInTime(fourDaysToMaturity);
          tx = await marketHarness
            .connect(laura)
            .repayMaturityWithReturnValue(nextPoolID, parseUnits("5250"), parseUnits("5250"), laura.address);
          returnValue = await marketHarness.returnValue();
          mp = await marketHarness.fixedPools(nextPoolID);
          fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(parseUnits("100"));
          fixedPoolState.earningsDiscounted = parseUnits("5250").sub(returnValue);
        });
        it("THEN borrowed is 5000", async () => {
          expect(mp.borrowed).to.eq(parseUnits("5000"));
        });
        it("THEN all unassignedEarnings should be 200", async () => {
          // 200 = 500 original - 100 accrued - 200 discount
          expect(mp.unassignedEarnings).to.eq(parseUnits("200"));
        });
        it("THEN the debtCovered returned is 5250", async () => {
          await expect(tx)
            .to.emit(marketHarness, "RepayAtMaturity")
            .withArgs(nextPoolID, laura.address, laura.address, parseUnits("5050"), parseUnits("5250"));
        });
        it("THEN the earningsSP returned are 100", async () => {
          const smartPoolAssets = await marketHarness.smartPoolAssets();
          const earnings = parseUnits("100"); // =1/5th of 500 since one day went by
          await expect(tx)
            .to.emit(marketHarness, "SmartPoolEarningsAccrued")
            .withArgs(smartPoolAssets.sub(earnings), earnings);
        });
        it("THEN the actualRepayAmount returned is 5050 (got a 200 discount)", async () => {
          expect(returnValue).to.eq(parseUnits("5050"));
        });

        describe("AND WHEN an early repayment of 5250", () => {
          beforeEach(async () => {
            await marketEnv.moveInTime(threeDaysToMaturity);
            tx = await marketHarness
              .connect(laura)
              .repayMaturityWithReturnValue(nextPoolID, parseUnits("5250"), parseUnits("5250"), laura.address);
            returnValue = await marketHarness.returnValue();
            mp = await marketHarness.fixedPools(nextPoolID);
            fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(parseUnits("50"));
            fixedPoolState.earningsDiscounted = fixedPoolState.earningsDiscounted.add(
              parseUnits("5250").sub(returnValue),
            );
          });
          it("THEN borrowed is 0", async () => {
            expect(mp.borrowed).to.eq(0);
          });
          it("THEN supplied is 0", async () => {
            expect(mp.supplied).to.eq(0);
          });
          it("THEN all unassignedEarnings should be 0", async () => {
            expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
          });
          it("THEN the debtCovered returned is 5250", async () => {
            await expect(tx)
              .to.emit(marketHarness, "RepayAtMaturity")
              .withArgs(nextPoolID, laura.address, laura.address, parseUnits("5100"), parseUnits("5250"));
          });
          it("THEN the earningsSP returned are 50", async () => {
            const smartPoolAssets = await marketHarness.smartPoolAssets();
            const earnings = parseUnits("50"); // 1 day passed (1/5) since last accrual
            await expect(tx)
              .to.emit(marketHarness, "SmartPoolEarningsAccrued")
              .withArgs(smartPoolAssets.sub(earnings), earnings);
          });
          it("THEN the actualRepayAmount returned is 5100 (got a 150 discount)", async () => {
            expect(returnValue).to.eq(parseUnits("5100"));
          });
          it("THEN the borrow fees are equal to all earnings distributed", async () => {
            expect(fixedPoolState.borrowFees).to.eq(marketEnv.getAllEarnings(fixedPoolState));
          });
        });
        describe("AND WHEN an early repayment of 5250 with a backupFeeRate of 10%", () => {
          beforeEach(async () => {
            await marketHarness.setBackupFeeRate(parseUnits("0.1"));
            await marketEnv.moveInTime(threeDaysToMaturity);
            tx = await marketHarness
              .connect(laura)
              .repayMaturityWithReturnValue(nextPoolID, parseUnits("5250"), parseUnits("5250"), laura.address);
            returnValue = await marketHarness.returnValue();
            mp = await marketHarness.fixedPools(nextPoolID);
            fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(parseUnits("50"));
            fixedPoolState.earningsAccumulator = await marketHarness.smartPoolEarningsAccumulator();
            fixedPoolState.earningsDiscounted = fixedPoolState.earningsDiscounted.add(
              parseUnits("5250").sub(returnValue),
            );
          });
          it("THEN borrowed is 0", async () => {
            expect(mp.borrowed).to.eq(0);
          });
          it("THEN supplied is 0", async () => {
            expect(mp.supplied).to.eq(0);
          });
          it("THEN all unassignedEarnings should be 0", async () => {
            expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
          });
          it("THEN the debtCovered returned is 5250", async () => {
            await expect(tx)
              .to.emit(marketHarness, "RepayAtMaturity")
              .withArgs(nextPoolID, laura.address, laura.address, parseUnits("5115"), parseUnits("5250"));
          });
          it("THEN the earningsSP returned are 50 accrued", async () => {
            const smartPoolAssets = await marketHarness.smartPoolAssets();
            const earnings = parseUnits("50");
            await expect(tx)
              .to.emit(marketHarness, "SmartPoolEarningsAccrued")
              .withArgs(smartPoolAssets.sub(earnings), earnings);
          });
          it("THEN the smartPoolEarningsAccumulator are 15 (10% backupFeeRate)", async () => {
            expect(await marketHarness.smartPoolEarningsAccumulator()).to.eq(parseUnits("15"));
          });
          it("THEN the actualRepayAmount returned is 5115 = 5250 - earningsSP(t-1)(are 50) - earningsSP(t)(are 50) - accumulator(t)(are 15)", async () => {
            expect(returnValue).to.eq(parseUnits("5115"));
          });
          it("THEN the borrow fees are equal to all earnings distributed", async () => {
            expect(fixedPoolState.borrowFees).to.eq(marketEnv.getAllEarnings(fixedPoolState));
          });
        });
      });
    });

    describe("GIVEN a borrowMP of 5000 (250 fees owed by user) AND a depositMP of 5000 (earns 250 in fees)", () => {
      beforeEach(async () => {
        borrowAmount = 5000;
        marketEnv.switchWallet(laura);
        await mockInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await marketEnv.moveInTime(fiveDaysToMaturity);
        await marketHarness
          .connect(laura)
          .borrowMaturityWithReturnValue(
            nextPoolID,
            parseUnits(borrowAmount.toString()),
            parseUnits((borrowAmount * 1.05).toString()),
            laura.address,
            laura.address,
          );
        returnValue = await marketHarness.returnValue();
        fixedPoolState.borrowFees = returnValue.sub(parseUnits(borrowAmount.toString()));

        await marketEnv.moveInTime(fourDaysToMaturity);
        tx = await marketHarness
          .connect(laura)
          .depositMaturityWithReturnValue(nextPoolID, parseUnits("5000"), parseUnits("5000"), laura.address);

        returnValue = await marketHarness.returnValue();

        mp = await marketHarness.fixedPools(nextPoolID);
        fixedPoolState.earningsMP = returnValue.sub(parseUnits("5000"));
        fixedPoolState.earningsDiscounted = parseUnits("0");
        fixedPoolState.earningsSP = parseUnits("50");
      });
      it("THEN all unassignedEarnings should be 0", async () => {
        expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
      });
      it("THEN the earningsSP returned are 50", async () => {
        const smartPoolAssets = await marketHarness.smartPoolAssets();
        const earnings = parseUnits("50");
        await expect(tx)
          .to.emit(marketHarness, "SmartPoolEarningsAccrued")
          .withArgs(smartPoolAssets.sub(earnings), earnings);
      });
      it("THEN the currentTotalDeposit returned is 5000 + 200 (earned fees)", async () => {
        expect(returnValue).eq(parseUnits("5200"));
      });

      describe("WHEN an early repayment of 5250", () => {
        beforeEach(async () => {
          tx = await marketHarness
            .connect(laura)
            .repayMaturityWithReturnValue(nextPoolID, parseUnits("5250"), parseUnits("5250"), laura.address);
          returnValue = await marketHarness.returnValue();
          mp = await marketHarness.fixedPools(nextPoolID);
        });
        it("THEN borrowed is 0", async () => {
          expect(mp.borrowed).to.eq(parseUnits("0"));
        });
        it("THEN all unassignedEarnings should be 0", async () => {
          expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
        });
        it("THEN the earningsSP returned are 0", async () => {
          const smartPoolAssets = await marketHarness.smartPoolAssets();
          await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
        });
        it("THEN the debtCovered returned is 5250", async () => {
          await expect(tx)
            .to.emit(marketHarness, "RepayAtMaturity")
            .withArgs(nextPoolID, laura.address, laura.address, parseUnits("5250"), parseUnits("5250"));
        });
        it("THEN the actualRepayAmount returned is 5250 (didn't get a discount since it was gotten all before)", async () => {
          expect(returnValue).to.eq(parseUnits("5250"));
        });
        it("THEN the borrow fees are equal to all earnings distributed", async () => {
          expect(fixedPoolState.borrowFees).to.eq(marketEnv.getAllEarnings(fixedPoolState));
        });
      });

      describe("WHEN an early withdrawal of 5250 without enough slippage", () => {
        let tx: any;
        beforeEach(async () => {
          tx = marketHarness
            .connect(laura)
            .withdrawMaturityWithReturnValue(
              nextPoolID,
              parseUnits("5250"),
              parseUnits("5250"),
              laura.address,
              laura.address,
            );
        });
        it("THEN it should revert with error TOO_MUCH_SLIPPAGE", async () => {
          await expect(tx).to.be.revertedWith("TooMuchSlippage()");
        });
      });

      describe("WHEN an early withdrawal of 5250 (deposited + fees) and a borrow rate shoots to 10%", () => {
        beforeEach(async () => {
          await mockInterestRateModel.setBorrowRate(parseUnits("0.1"));
          tx = await marketHarness
            .connect(laura)
            .withdrawMaturityWithReturnValue(
              nextPoolID,
              parseUnits("5250"),
              parseUnits("4500"),
              laura.address,
              laura.address,
            );
          returnValue = await marketHarness.returnValue();
          mp = await marketHarness.fixedPools(nextPoolID);
        });
        it("THEN borrowed is 5000", async () => {
          // 4772.72 is the real value that the smart pool needed to cover
          // but for simplicity it will cover the full 5000
          // the difference between 4772.72 and 5000 is the amount we added to the unassigned earnings due to the high borrow rate when withdrawing
          expect(mp.borrowed).to.eq(parseUnits("5000"));
        });
        it("THEN unassignedEarnings should be 477 (250 + money left on the table)", async () => {
          expect(mp.unassignedEarnings).to.eq(parseUnits("472.727272727272727273"));
        });
        it("THEN supplied should be 0", async () => {
          expect(mp.supplied).to.eq(parseUnits("0"));
        });
        it("THEN the redeemAmountDiscounted returned is 4772", async () => {
          // 5250 / 1.10 (1e18 + 1e17 feeRate) = 4772.72727272727272727272
          expect(returnValue).to.be.eq(parseUnits("4727.272727272727272727"));
        });
        it("THEN the earningsSP returned is 0", async () => {
          const smartPoolAssets = await marketHarness.smartPoolAssets();
          await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
        });
        it("THEN the fixedDepositPositions is 0", async () => {
          const fixedDepositPositions = await marketHarness.fixedDepositPositions(nextPoolID, laura.address);

          expect(fixedDepositPositions[0]).to.be.eq(parseUnits("0"));
          expect(fixedDepositPositions[1]).to.be.eq(parseUnits("0"));
        });
      });

      describe("WHEN an early withdrawal of 5200 (deposited + fees)", () => {
        beforeEach(async () => {
          tx = await marketHarness
            .connect(laura)
            .withdrawMaturityWithReturnValue(
              nextPoolID,
              parseUnits("5200"),
              parseUnits("4500"),
              laura.address,
              laura.address,
            );
          returnValue = await marketHarness.returnValue();
          mp = await marketHarness.fixedPools(nextPoolID);
        });
        it("THEN borrowed is 0", async () => {
          expect(mp.borrowed).to.eq(parseUnits("5000"));
        });
        it("THEN unassignedEarnings should be 250 again", async () => {
          // 5200 / 1.05 = 4952;
          // 5200 - 4952 = ~248;
          expect(mp.unassignedEarnings).to.eq(parseUnits("247.619047619047619048"));
        });
        it("THEN the redeemAmountDiscounted returned is 5000", async () => {
          // 5200 / 1.05 (1e18 + 5e16 feeRate) = 4952
          expect(returnValue).to.be.eq(parseUnits("4952.380952380952380952"));
        });
        it("THEN the earningsSP returned is 0", async () => {
          const smartPoolAssets = await marketHarness.smartPoolAssets();
          await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
        });
        it("THEN the fixedDepositPositions is 0", async () => {
          const fixedDepositPositions = await marketHarness.fixedDepositPositions(nextPoolID, laura.address);

          expect(fixedDepositPositions[0]).to.be.eq(parseUnits("0"));
          expect(fixedDepositPositions[1]).to.be.eq(parseUnits("0"));
        });
      });
      describe("AND GIVEN a deposit of 5250", () => {
        beforeEach(async () => {
          await marketHarness
            .connect(laura)
            .depositMaturityWithReturnValue(nextPoolID, parseUnits("5250"), parseUnits("5250"), laura.address);
        });
        describe("WHEN an early withdrawal of 5250 (deposited + fees)", () => {
          beforeEach(async () => {
            tx = await marketHarness
              .connect(laura)
              .withdrawMaturityWithReturnValue(
                nextPoolID,
                parseUnits("5250"),
                parseUnits("4500"),
                laura.address,
                laura.address,
              );
            mp = await marketHarness.fixedPools(nextPoolID);
          });
          it("THEN unassignedEarnings is 0", async () => {
            expect(mp.unassignedEarnings).to.eq(parseUnits("0"));
          });
          it("THEN the earningsSP returned is 0", async () => {
            const smartPoolAssets = await marketHarness.smartPoolAssets();
            await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
          });
          it("THEN the smartPoolEarningsAccumulator returned is 250", async () => {
            expect(await marketHarness.smartPoolEarningsAccumulator()).eq(parseUnits("250"));
          });
        });
      });
      describe("AND GIVEN a deposit of 2625", () => {
        beforeEach(async () => {
          await marketHarness
            .connect(laura)
            .depositMaturityWithReturnValue(nextPoolID, parseUnits("2625"), parseUnits("2625"), laura.address);
        });
        describe("WHEN an early withdrawal of 5250 (deposited + fees)", () => {
          beforeEach(async () => {
            tx = await marketHarness
              .connect(laura)
              .withdrawMaturityWithReturnValue(
                nextPoolID,
                parseUnits("5250"),
                parseUnits("4500"),
                laura.address,
                laura.address,
              );
            mp = await marketHarness.fixedPools(nextPoolID);
          });
          it("THEN unassignedEarnings is 125", async () => {
            expect(mp.unassignedEarnings).to.eq(parseUnits("124.540734824281150160"));
          });
          it("THEN the earningsSP returned is 0", async () => {
            const smartPoolAssets = await marketHarness.smartPoolAssets();
            await expect(tx).to.emit(marketHarness, "SmartPoolEarningsAccrued").withArgs(smartPoolAssets, 0);
          });
          it("THEN the smartPoolEarningsAccumulator returned is 125", async () => {
            expect(await marketHarness.smartPoolEarningsAccumulator()).eq(parseUnits("125.459265175718849840"));
          });
        });
      });
    });

    describe("User receives more money than deposited for repaying earlier", () => {
      describe("GIVEN a borrowMP of 10000 (2000 fees owed by user) (5 days to maturity)", () => {
        beforeEach(async () => {
          marketEnv.switchWallet(laura);
          await mockInterestRateModel.setBorrowRate(parseUnits("0.2"));
          await marketEnv.moveInTime(fiveDaysToMaturity);
          await marketHarness
            .connect(laura)
            .borrowMaturityWithReturnValue(
              nextPoolID,
              parseUnits("10000"),
              parseUnits("12000"),
              laura.address,
              laura.address,
            );
          mp = await marketHarness.fixedPools(nextPoolID);
        });

        it("THEN all unassignedEarnings should be 2000", () => {
          expect(mp.unassignedEarnings).to.eq(parseUnits("2000"));
        });

        describe("GIVEN a borrowMP of 10000 (10000 fees owed by user) (4 days to maturity)", () => {
          beforeEach(async () => {
            marketEnv.switchWallet(tina);
            await mockInterestRateModel.setBorrowRate(parseUnits("1")); // Crazy FEE
            await marketEnv.moveInTime(fourDaysToMaturity);
            await marketHarness
              .connect(laura)
              .borrowMaturityWithReturnValue(
                nextPoolID,
                parseUnits("10000"),
                parseUnits("20000"),
                laura.address,
                laura.address,
              ); // ... and we accept it
            mp = await marketHarness.fixedPools(nextPoolID);
          });

          it("THEN all unassignedEarnings should be 11600", async () => {
            // 400 out of 2000 accrued because 1 day went by for the original 2000
            expect(mp.unassignedEarnings).to.eq(parseUnits("11600"));
          });

          describe("WHEN an early repayment of 16000 (3 days to maturity)", () => {
            beforeEach(async () => {
              marketEnv.switchWallet(laura);
              await marketEnv.moveInTime(threeDaysToMaturity);
              tx = await marketHarness
                .connect(laura)
                .repayMaturityWithReturnValue(nextPoolID, parseUnits("16000"), parseUnits("16000"), laura.address);
              returnValue = await marketHarness.returnValue();
              mp = await marketHarness.fixedPools(nextPoolID);
            });
            it("THEN borrowed is 10000", async () => {
              expect(mp.borrowed).to.eq(parseUnits("10000"));
            });
            it("THEN all unassignedEarnings should be 4350", async () => {
              // 11600 * .75 = 8700 => unassigned before operation after accrual (1 out of 4 days went by)
              // 8700 / 2 = 4350 => covering half sp debt gives half of the unassigned
              expect(mp.unassignedEarnings).to.eq(parseUnits("4350"));
            });
            it("THEN the debtCovered returned is 16000", async () => {
              await expect(tx)
                .to.emit(marketHarness, "RepayAtMaturity")
                .withArgs(nextPoolID, laura.address, laura.address, parseUnits("11650"), parseUnits("16000"));
            });
            it("THEN the earningsSP returned are 2900", async () => {
              const smartPoolAssets = await marketHarness.smartPoolAssets();
              // 11600 * .25 = 2900 => (1 out of 4 days went by)
              const earnings = parseUnits("2900");
              await expect(tx)
                .to.emit(marketHarness, "SmartPoolEarningsAccrued")
                .withArgs(smartPoolAssets.sub(earnings), earnings);
            });
            it("THEN the actualRepayAmount returned is 11650 (got a 4350 discount)", async () => {
              // Repaying 16000 minus 4350 for the half taken from unassigned earnings
              expect(returnValue).to.eq(parseUnits("11650"));
            });
          });
        });
      });
    });
  });

  afterEach(async () => {
    await provider.send("evm_revert", [snapshot]);
  });
});
