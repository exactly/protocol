import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { FixedPoolState } from "./exactlyUtils";
import { FixedLenderEnv } from "./fixedLenderEnv";
import futurePools, { INTERVAL } from "./utils/futurePools";

const { provider } = ethers;
const nextPoolID = futurePools(3)[2].toNumber();

describe("FixedLender Internal Functions", () => {
  let laura: SignerWithAddress;
  let tina: SignerWithAddress;
  let fixedLenderEnv: FixedLenderEnv;
  let fixedLenderHarness: Contract;
  let mockInterestRateModel: Contract;
  let snapshot: any;

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
    [, laura, tina] = await ethers.getSigners();
    fixedLenderEnv = await FixedLenderEnv.create();
    fixedLenderHarness = fixedLenderEnv.fixedLenderHarness;
    mockInterestRateModel = fixedLenderEnv.mockInterestRateModel;
  });

  describe("setPenaltyRate", () => {
    it("WHEN calling setPenaltyRate, THEN the penaltyRate should be updated", async () => {
      const penaltyRate = parseUnits("0.03").div(86_400);
      await fixedLenderHarness.setPenaltyRate(penaltyRate);
      expect(await fixedLenderHarness.penaltyRate()).to.be.equal(penaltyRate);
    });
    it("WHEN calling setPenaltyRate, THEN it should emit PenaltyRateSet event", async () => {
      const penaltyRate = parseUnits("0.04").div(86_400);
      await expect(await fixedLenderHarness.setPenaltyRate(penaltyRate))
        .to.emit(fixedLenderHarness, "PenaltyRateSet")
        .withArgs(penaltyRate);
    });
    it("WHEN calling setPenaltyRate from a regular (non-admin) user, THEN it reverts with an AccessControl error", async () => {
      await expect(fixedLenderHarness.connect(laura).setPenaltyRate(parseUnits("0.04"))).to.be.revertedWith(
        "AccessControl",
      );
    });
  });
  describe("setSmartPoolReserveFactor", () => {
    it("WHEN calling setSmartPoolReserveFactor, THEN the smartPoolReserveFactor should be updated", async () => {
      await fixedLenderHarness.setSmartPoolReserveFactor(parseUnits("0.04"));
      expect(await fixedLenderHarness.smartPoolReserveFactor()).to.be.equal(parseUnits("0.04"));
    });
    it("WHEN calling setSmartPoolReserveFactor, THEN it should emit SmartPoolReserveFactorSet event", async () => {
      await expect(await fixedLenderHarness.setSmartPoolReserveFactor(parseUnits("0.04")))
        .to.emit(fixedLenderHarness, "SmartPoolReserveFactorSet")
        .withArgs(parseUnits("0.04"));
    });
    it("WHEN calling setSmartPoolReserveFactor from a regular (non-admin) user, THEN it reverts with an AccessControl error", async () => {
      await expect(fixedLenderHarness.connect(laura).setSmartPoolReserveFactor(parseUnits("0.04"))).to.be.revertedWith(
        "AccessControl",
      );
    });
  });
  describe("setInterestRateModel", () => {
    let newInterestRateModel: Contract;
    before(async () => {
      const InterestRateModelFactory = await ethers.getContractFactory("InterestRateModel");

      newInterestRateModel = await InterestRateModelFactory.deploy(
        parseUnits("0.75"),
        parseUnits("-0.105"),
        parseUnits("6"),
        parseUnits("4"),
        parseUnits("0"),
      );
      await newInterestRateModel.deployed();
    });

    it("WHEN calling setInterestRateModel, THEN the interestRateModel should be updated", async () => {
      const interestRateModelBefore = await fixedLenderHarness.interestRateModel();
      await fixedLenderHarness.setInterestRateModel(newInterestRateModel.address);
      expect(await fixedLenderHarness.interestRateModel()).to.not.equal(interestRateModelBefore);
    });
    it("WHEN calling setInterestRateModel, THEN it should emit InterestRateModelSet event", async () => {
      await expect(await fixedLenderHarness.setInterestRateModel(newInterestRateModel.address))
        .to.emit(fixedLenderHarness, "InterestRateModelSet")
        .withArgs(newInterestRateModel.address);
    });
    it("WHEN calling setInterestRateModel from a regular (non-admin) user, THEN it reverts with an AccessControl error", async () => {
      await expect(
        fixedLenderHarness.connect(laura).setInterestRateModel(newInterestRateModel.address),
      ).to.be.revertedWith("AccessControl");
    });
  });

  describe("GIVEN a depositMP with an amount of 10000 (0 fees earned)", () => {
    const sixDaysToMaturity = nextPoolID - 86_400 * 5;
    let depositAmount: any;
    let withdrawAmount: any;
    let borrowAmount: any;
    let borrowFees: any;
    let returnValues: any;
    let repayAmount: any;
    let fixedDepositPositions: any;
    let fixedBorrowPositions: any;
    let mp: any;
    let fixedPoolState: FixedPoolState;

    beforeEach(async () => {
      fixedPoolState = {
        borrowFees: parseUnits("0"),
        earningsUnassigned: parseUnits("0"),
        earningsSP: parseUnits("0"),
        earningsAccumulator: parseUnits("0"),
        earningsMP: parseUnits("0"),
        earningsDiscounted: parseUnits("0"),
      };

      depositAmount = "10000";

      fixedLenderEnv.switchWallet(laura);
      await fixedLenderEnv.moveInTime(sixDaysToMaturity);
      await fixedLenderEnv.depositMP(nextPoolID, depositAmount);

      returnValues = await fixedLenderHarness.returnValues();
      mp = await fixedLenderHarness.fixedPools(nextPoolID);
      fixedDepositPositions = await fixedLenderHarness.fixedDepositPositions(nextPoolID, laura.address);
    });
    it("THEN borrowed equals 0", async () => {
      expect(mp.borrowed).to.eq(parseUnits("0"));
    });
    it("THEN supplied equals to depositedAmount", async () => {
      expect(mp.supplied).to.eq(parseUnits(depositAmount));
    });
    it("THEN earningsUnassigned are 0", async () => {
      expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
    });
    it("THEN lastAccrual is 6 days to maturity", async () => {
      expect(mp.lastAccrual).to.eq(sixDaysToMaturity);
    });
    it("THEN the fixedDepositPositions is correctly updated", async () => {
      expect(fixedDepositPositions[0]).to.be.eq(parseUnits(depositAmount.toString()));
      expect(fixedDepositPositions[1]).to.be.eq(parseUnits("0"));
    });
    it("THEN the earningsSP returned are 0", async () => {
      expect(returnValues.earningsSP).to.eq(parseUnits("0"));
    });
    it("THEN the currentTotalDeposit returned is equal to the amount (no fees earned)", async () => {
      expect(returnValues.currentTotalDeposit).to.eq(parseUnits(depositAmount));
    });

    describe("AND GIVEN a borrowMP with an amount of 5000 (250 charged in fees to accumulator) (4 days to go)", () => {
      const fourDaysToMaturity = nextPoolID - 86_400 * 4;
      beforeEach(async () => {
        borrowAmount = 5000;
        borrowFees = 250;
        await mockInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await fixedLenderEnv.moveInTime(fourDaysToMaturity);
        await fixedLenderEnv.borrowMP(nextPoolID, borrowAmount.toString(), (borrowAmount + borrowFees).toString());

        fixedBorrowPositions = await fixedLenderHarness.fixedBorrowPositions(nextPoolID, laura.address);
        returnValues = await fixedLenderHarness.returnValues();
        mp = await fixedLenderHarness.fixedPools(nextPoolID);
        fixedPoolState.earningsAccumulator = await fixedLenderHarness.smartPoolEarningsAccumulator();
        fixedPoolState.borrowFees = returnValues.totalOwedNewBorrow.sub(parseUnits(borrowAmount.toString()));
      });
      it("THEN borrowed is the just borrowed amount", async () => {
        expect(mp.borrowed).to.eq(parseUnits(borrowAmount.toString()));
      });
      it("THEN supplied is the just deposited amount", async () => {
        expect(mp.supplied).to.eq(parseUnits(depositAmount));
      });
      it("THEN earningsUnassigned are 0", async () => {
        expect(mp.earningsUnassigned).to.eq(0);
      });
      it("THEN lastAccrual is 4 days to maturity", async () => {
        expect(mp.lastAccrual).to.eq(fourDaysToMaturity);
      });
      it("THEN the fixedBorrowPositions is correctly updated", async () => {
        expect(fixedBorrowPositions[0]).to.be.eq(parseUnits(borrowAmount.toString()));
        expect(fixedBorrowPositions[1]).to.be.eq(parseUnits(borrowFees.toString()));
      });
      it("THEN the smartPoolEarningsAccumulator are 250", async () => {
        expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.eq(
          parseUnits(borrowFees.toString()), // 5000 x 0,05 (5%)
        );
      });
      it("THEN the earningsSP returned are 0", async () => {
        expect(returnValues.earningsSP).to.eq(parseUnits("0"));
      });
      it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
        expect(returnValues.totalOwedNewBorrow).to.eq(parseUnits((borrowAmount + borrowFees).toString()));
      });

      describe("AND GIVEN another borrowMP call with an amount of 5000 (250 charged in fees to smartPoolEarningsAccumulator) (3 days to go)", () => {
        const threeDaysToMaturity = nextPoolID - 86_400 * 3;
        beforeEach(async () => {
          borrowAmount = 5000;
          borrowFees = 250;
          await fixedLenderEnv.moveInTime(threeDaysToMaturity);
          await fixedLenderEnv.borrowMP(nextPoolID, borrowAmount.toString(), (borrowAmount + borrowFees).toString());

          fixedBorrowPositions = await fixedLenderHarness.fixedBorrowPositions(nextPoolID, laura.address);
          returnValues = await fixedLenderHarness.returnValues();
          mp = await fixedLenderHarness.fixedPools(nextPoolID);
          fixedPoolState.earningsAccumulator = await fixedLenderHarness.smartPoolEarningsAccumulator();
          fixedPoolState.borrowFees = fixedPoolState.borrowFees.add(
            returnValues.totalOwedNewBorrow.sub(parseUnits(borrowAmount.toString())),
          );
          fixedPoolState.earningsUnassigned = parseUnits("0");
        });
        it("THEN borrowed is 2x the previously borrow amount", async () => {
          expect(mp.borrowed).to.eq(parseUnits((borrowAmount * 2).toString()));
        });
        it("THEN supplied is the one depositedAmount", async () => {
          expect(mp.supplied).to.eq(parseUnits(depositAmount.toString()));
        });
        it("THEN earningsUnassigned are 0", async () => {
          expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
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
          expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.eq(
            parseUnits((borrowFees * 2).toString()),
          );
        });
        it("THEN the earningsSP returned are 0", async () => {
          expect(returnValues.earningsSP).to.eq(0);
        });
        it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
          expect(returnValues.totalOwedNewBorrow).to.eq(parseUnits((borrowAmount + borrowFees).toString()));
        });
        it("THEN the borrow fees are equal to all earnings distributed", async () => {
          expect(fixedPoolState.borrowFees).to.eq(fixedLenderEnv.getAllEarnings(fixedPoolState));
        });

        describe("AND GIVEN another borrowMP call with an amount of 5000 (250 charged in fees to unassigned) (2 days to go)", () => {
          const oneDayToMaturity = nextPoolID - 86_400;
          const twoDaysToMaturity = nextPoolID - 86_400 * 2;
          beforeEach(async () => {
            borrowAmount = 5000;
            borrowFees = 250;
            await fixedLenderEnv.moveInTime(twoDaysToMaturity);
            await fixedLenderEnv.borrowMP(nextPoolID, borrowAmount.toString(), (borrowAmount + borrowFees).toString());

            returnValues = await fixedLenderHarness.returnValues();
            mp = await fixedLenderHarness.fixedPools(nextPoolID);
            fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
            fixedPoolState.borrowFees = fixedPoolState.borrowFees.add(
              returnValues.totalOwedNewBorrow.sub(parseUnits(borrowAmount.toString())),
            );
            fixedPoolState.earningsUnassigned = fixedPoolState.earningsUnassigned.add(mp.earningsUnassigned);
          });
          it("THEN borrowed is 3x the borrowAmount", async () => {
            expect(mp.borrowed).to.eq(parseUnits((borrowAmount * 3).toString()));
          });
          it("THEN supplied is 1x depositAmount", async () => {
            expect(mp.supplied).to.eq(parseUnits(depositAmount));
          });
          it("THEN earningsUnassigned are 250", async () => {
            expect(mp.earningsUnassigned).to.eq(parseUnits(borrowFees.toString()));
          });
          it("THEN lastAccrual is 2 days to maturity", async () => {
            expect(mp.lastAccrual).to.eq(twoDaysToMaturity);
          });
          it("THEN the smartPoolEarningsAccumulator are still 500", async () => {
            expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.eq(
              parseUnits((borrowFees * 2).toString()),
            );
          });
          it("THEN the earningsSP returned are 0", async () => {
            expect(returnValues.earningsSP).to.eq(parseUnits("0"));
          });
          it("THEN the totalOwedNewBorrow returned is equal to the amount plus fees charged", async () => {
            expect(returnValues.totalOwedNewBorrow).to.eq(parseUnits((borrowAmount + borrowFees).toString()));
          });
          it("THEN the borrow fees are equal to all earnings distributed", async () => {
            expect(fixedPoolState.borrowFees).to.eq(fixedLenderEnv.getAllEarnings(fixedPoolState));
          });

          describe("AND GIVEN a repayMP with an amount of 15750 (total EARLY repayment) (1 day to go)", () => {
            let mp: any;
            beforeEach(async () => {
              repayAmount = 15750;
              await fixedLenderEnv.moveInTime(oneDayToMaturity);
              await fixedLenderEnv.repayMP(nextPoolID, repayAmount.toString());

              fixedBorrowPositions = await fixedLenderHarness.fixedBorrowPositions(nextPoolID, laura.address);
              returnValues = await fixedLenderHarness.returnValues();
              fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
              mp = await fixedLenderHarness.fixedPools(nextPoolID);
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
              expect(returnValues.debtCovered).to.eq(parseUnits("15750"));
            });
            it("THEN the fixedBorrowPositions position is 0", async () => {
              expect(fixedBorrowPositions[0]).to.be.eq(0);
              expect(fixedBorrowPositions[1]).to.be.eq(0);
            });
            it("THEN the smartPoolEarningsAccumulator are still 500", async () => {
              expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.eq(
                parseUnits((borrowFees * 2).toString()),
              );
            });
            it("THEN earningsSP returned 125", async () => {
              expect(returnValues.earningsSP).to.eq(parseUnits("125")); // earningsUnassigned were 250, then 1 day passed so earningsSP accrued half
            });
            it("THEN the actualRepayAmount returned is 15750 - 125", async () => {
              // Takes all the unassignedEarnings
              // first 500 were taken by the treasury
              // then 125 was accrued and earned by the SP
              // then the repay takes the rest as a discount
              expect(returnValues.actualRepayAmount).to.eq(parseUnits((repayAmount - 125).toString()));
            });
          });

          describe("AND GIVEN a repayMP with an amount of 8000 (partial EARLY repayment) (1 day to go)", () => {
            let mp: any;
            beforeEach(async () => {
              repayAmount = 8000;
              await fixedLenderEnv.moveInTime(oneDayToMaturity);
              await fixedLenderEnv.repayMP(nextPoolID, repayAmount.toString());

              fixedBorrowPositions = await fixedLenderHarness.fixedBorrowPositions(nextPoolID, laura.address);
              returnValues = await fixedLenderHarness.returnValues();
              fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
              mp = await fixedLenderHarness.fixedPools(nextPoolID);
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
              expect(returnValues.debtCovered).to.eq(parseUnits("8000"));
            });
            it("THEN the fixedBorrowPositions is correctly updated (principal + fees = 7750)", async () => {
              expect(fixedBorrowPositions[0]).to.be.gt(parseUnits("7380"));
              expect(fixedBorrowPositions[0]).to.be.lt(parseUnits("7381"));
              expect(fixedBorrowPositions[1]).to.be.gt(parseUnits("369"));
              expect(fixedBorrowPositions[1]).to.be.lt(parseUnits("370"));
            });
            it("THEN the smartPoolEarningsAccumulator are still 500", async () => {
              expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.eq(
                parseUnits((borrowFees * 2).toString()),
              );
            });
            it("THEN earningsSP returned 125", async () => {
              expect(returnValues.earningsSP).to.eq(parseUnits("125")); // earningsUnassigned were 250, then 1 day passed so earningsSP accrued half
            });
            it("THEN the actualRepayAmount returned is 8000 - 125", async () => {
              // Takes all the unassignedEarnings
              // first 500 were taken by the treasury
              // then 125 was accrued and earned by the SP
              // then the repay takes the rest as a discount
              expect(returnValues.actualRepayAmount).to.eq(parseUnits((repayAmount - 125).toString()));
            });
          });

          describe("AND GIVEN a repayMP at maturity(-1 DAY) with an amount of 15750 but asking a 126 discount (total EARLY repayment) ", () => {
            let tx: any;
            beforeEach(async () => {
              await fixedLenderEnv.moveInTime(oneDayToMaturity);
              repayAmount = 15750;
              tx = fixedLenderEnv.repayMP(nextPoolID, repayAmount.toString(), (repayAmount - 126).toString());
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
              await fixedLenderHarness.setFreePenaltyRate(parseUnits("0.1").div(86_400));
              await fixedLenderEnv.moveInTime(nextPoolID + 86_400);
              repayAmount = 17325;
              await fixedLenderEnv.repayMP(nextPoolID, repayAmount.toString());

              fixedBorrowPositions = await fixedLenderHarness.fixedBorrowPositions(nextPoolID, laura.address);
              returnValues = await fixedLenderHarness.returnValues();
              fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
              mp = await fixedLenderHarness.fixedPools(nextPoolID);
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
              expect(returnValues.debtCovered).to.eq(parseUnits("15750"));
            });
            it("THEN earningsSP receive no % of penalties", async () => {
              // 250 (previous earnings unassigned)
              expect(returnValues.earningsSP).to.eq(parseUnits("250"));
            });
            it("THEN the smartPoolEarningsAccumulator receives all penalties", async () => {
              // 17325 - 15750 = 1575
              // + 500 (previous accumulated earnings)
              expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.gt(parseUnits("2074"));
              expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.lt(parseUnits("2075"));
            });
            it("THEN the fixedBorrowPositions position is 0", async () => {
              expect(fixedBorrowPositions[0]).to.be.eq(0);
              expect(fixedBorrowPositions[1]).to.be.eq(0);
            });
            it("THEN the actualRepayAmount returned is almost 17325", async () => {
              expect(returnValues.actualRepayAmount).to.lt(parseUnits(repayAmount.toString()));
              expect(returnValues.actualRepayAmount).to.gt(parseUnits((repayAmount - 0.1).toString()));
            });

            afterEach(async () => {
              await fixedLenderHarness.setFreePenaltyRate(0);
            });
          });

          describe("AND GIVEN another depositMP with an amount of 5000 (half of 250 unassigned earnings earned) (1 day to)", () => {
            beforeEach(async () => {
              depositAmount = 5000;

              await fixedLenderEnv.moveInTime(oneDayToMaturity);
              await fixedLenderEnv.depositMP(nextPoolID, depositAmount.toString());

              returnValues = await fixedLenderHarness.returnValues();
              mp = await fixedLenderHarness.fixedPools(nextPoolID);
              fixedPoolState.earningsAccumulator = await fixedLenderHarness.smartPoolEarningsAccumulator();
              fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
              fixedPoolState.earningsMP = returnValues.currentTotalDeposit.sub(parseUnits(depositAmount.toString()));
              fixedPoolState.earningsUnassigned = parseUnits("0");
              fixedDepositPositions = await fixedLenderHarness.fixedDepositPositions(nextPoolID, laura.address);
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
            it("THEN earningsUnassigned are 0", async () => {
              expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
            });
            it("THEN lastAccrual is 1 day to maturity", async () => {
              expect(mp.lastAccrual).to.eq(oneDayToMaturity);
            });
            it("THEN the fixedDepositPositions is correctly updated", async () => {
              expect(fixedDepositPositions[0]).to.be.eq(parseUnits((depositAmount + 10000).toString()));
              expect(fixedDepositPositions[1]).to.be.eq(parseUnits((250 / 2).toString()));
            });
            it("THEN the earningsSP returned are 125", async () => {
              expect(returnValues.earningsSP).to.eq(
                parseUnits((250 / 2).toString()), // 250 (previous unassigned) / 2 days
              );
            });
            it("THEN the smartPoolEarningsAccumulator are still 500", async () => {
              expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.eq(
                parseUnits((borrowFees * 2).toString()),
              );
            });
            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValues.currentTotalDeposit).to.eq(parseUnits((depositAmount + 250 / 2).toString()));
            });
            it("THEN the borrow fees are equal to all earnings distributed", async () => {
              expect(fixedPoolState.borrowFees).to.eq(fixedLenderEnv.getAllEarnings(fixedPoolState));
            });
          });

          describe("AND GIVEN another depositMP with an amount of 5000 and with a spFeeRate of 10% (125 - (125 * 0.1) fees earned)", () => {
            beforeEach(async () => {
              depositAmount = 5000;

              await mockInterestRateModel.setSPFeeRate(parseUnits("0.1")); // 10% fees charged from the mp depositor yield to the sp earnings
              await fixedLenderEnv.moveInTime(oneDayToMaturity);
              await fixedLenderEnv.depositMP(nextPoolID, depositAmount.toString());

              returnValues = await fixedLenderHarness.returnValues();
              mp = await fixedLenderHarness.fixedPools(nextPoolID);
              fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
              fixedPoolState.earningsAccumulator = await fixedLenderHarness.smartPoolEarningsAccumulator();
              fixedPoolState.earningsMP = returnValues.currentTotalDeposit.sub(parseUnits(depositAmount.toString()));
              fixedPoolState.earningsUnassigned = parseUnits("0");
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
            it("THEN earningsUnassigned are 0", async () => {
              expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
            });
            it("THEN lastAccrual is 1 day to maturity", async () => {
              expect(mp.lastAccrual).to.eq(oneDayToMaturity);
            });
            it("THEN the earningsSP returned are just 125", async () => {
              expect(returnValues.earningsSP).to.eq(
                parseUnits((250 / 2).toString()), // 250 (previous unassigned) / 2 days
              );
            });
            it("THEN the smartPoolEarningsAccumulator are 500 + 12.5", async () => {
              expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.eq(
                parseUnits((borrowFees * 2 + 12.5).toString()),
              );
            });
            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValues.currentTotalDeposit).to.eq(parseUnits((depositAmount + 250 / 2 - 12.5).toString()));
            });
            it("THEN the borrow fees are equal to all earnings distributed", async () => {
              expect(fixedPoolState.borrowFees).to.eq(fixedLenderEnv.getAllEarnings(fixedPoolState));
            });
          });

          describe("AND GIVEN another depositMP with an exorbitant amount of 100M (all fees earned - same as depositing only 5k)", () => {
            beforeEach(async () => {
              depositAmount = 100000000;

              await fixedLenderEnv.moveInTime(oneDayToMaturity);
              await fixedLenderEnv.depositMP(nextPoolID, depositAmount.toString());

              returnValues = await fixedLenderHarness.returnValues();
              fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
              mp = await fixedLenderHarness.fixedPools(nextPoolID);
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
            it("THEN earningsUnassigned are 0", async () => {
              expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
            });
            it("THEN lastAccrual is 1 day before maturity", async () => {
              expect(mp.lastAccrual).to.eq(oneDayToMaturity);
            });
            it("THEN the currentTotalDeposit returned is equal to the amount plus fees earned", async () => {
              expect(returnValues.currentTotalDeposit).to.eq(parseUnits((depositAmount + 125).toString()));
            });

            describe("AND GIVEN an EARLY repayMP with an amount of 5250 (12 hours to maturity)", () => {
              const twelveHoursToMaturity = nextPoolID - 3_600 * 12;

              beforeEach(async () => {
                repayAmount = 5250;

                await fixedLenderEnv.moveInTime(twelveHoursToMaturity);
                await fixedLenderEnv.repayMP(nextPoolID, repayAmount.toString());
                fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);

                returnValues = await fixedLenderHarness.returnValues();
                mp = await fixedLenderHarness.fixedPools(nextPoolID);
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
                expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.eq(
                  parseUnits((borrowFees * 2).toString()),
                );
              });
              it("THEN earningsUnassigned are still 0", async () => {
                expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                expect(returnValues.earningsSP).to.eq(parseUnits("0"));
              });
              it("THEN lastAccrual is 12 hours before maturity", async () => {
                expect(mp.lastAccrual).to.eq(twelveHoursToMaturity);
              });
              it("THEN the debtCovered was the full repayAmount", async () => {
                expect(returnValues.debtCovered).to.eq(parseUnits(repayAmount.toString()));
              });
            });

            describe("AND GIVEN a total EARLY repayMP with an amount of 15750 (all debt)", () => {
              const twelveHoursToMaturity = nextPoolID - 3_600 * 12;

              beforeEach(async () => {
                repayAmount = 15750;

                await fixedLenderEnv.moveInTime(twelveHoursToMaturity);
                await fixedLenderEnv.repayMP(nextPoolID, repayAmount.toString());

                mp = await fixedLenderHarness.fixedPools(nextPoolID);
                returnValues = await fixedLenderHarness.returnValues();
              });
              it("THEN earningsUnassigned are still 0", async () => {
                expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
              });
              it("THEN the debtCovered was the full amount repaid", async () => {
                expect(returnValues.debtCovered).to.eq(parseUnits(repayAmount.toString()));
              });
              it("THEN the earningsSP returned are 0", async () => {
                expect(returnValues.earningsSP).to.eq(parseUnits("0"));
              });
            });

            describe("AND GIVEN a total repayMP at maturity with an amount of 15750 (all debt)", () => {
              beforeEach(async () => {
                repayAmount = 15750;

                await fixedLenderEnv.moveInTime(nextPoolID);
                await fixedLenderEnv.repayMP(nextPoolID, repayAmount.toString());

                mp = await fixedLenderHarness.fixedPools(nextPoolID);
                returnValues = await fixedLenderHarness.returnValues();
              });
              it("THEN the maturity pool state is correctly updated", async () => {
                expect(mp.borrowed).to.eq(parseUnits("0"));
                expect(mp.supplied).to.eq(
                  parseUnits((depositAmount + 10000).toString()), // 1M + 10k deposit
                );
              });
              it("THEN the debtCovered was equal to full repayAmount", async () => {
                expect(returnValues.debtCovered).to.eq(parseUnits(repayAmount.toString()));
              });
              it("THEN earningsUnassigned are still 0", async () => {
                expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                expect(returnValues.earningsSP).to.eq(parseUnits("0"));
              });
              describe("AND GIVEN a partial withdrawMP of 50M", () => {
                beforeEach(async () => {
                  withdrawAmount = 50000000;

                  await fixedLenderEnv.withdrawMP(nextPoolID, withdrawAmount.toString());

                  mp = await fixedLenderHarness.fixedPools(nextPoolID);
                  returnValues = await fixedLenderHarness.returnValues();
                  fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
                  fixedDepositPositions = await fixedLenderHarness.fixedDepositPositions(nextPoolID, laura.address);
                });
                it("THEN the maturity pool state is correctly updated", async () => {
                  expect(mp.borrowed).to.eq(parseUnits("0"));
                  expect(mp.supplied).to.be.eq(fixedDepositPositions[0]);
                });
                it("THEN earningsUnassigned are still 0", async () => {
                  expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
                });
                it("THEN the earningsSP returned are 0", async () => {
                  expect(returnValues.earningsSP).to.eq(parseUnits("0"));
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
                  expect(returnValues.redeemAmountDiscounted).to.eq(parseUnits(withdrawAmount.toString()));
                });
                it("THEN the withdrawAmount + remaining fees + supplied that still remains in the pool equals initial total deposit", async () => {
                  const fixedDepositPositions = await fixedLenderHarness.fixedDepositPositions(
                    nextPoolID,
                    laura.address,
                  );

                  expect(returnValues.redeemAmountDiscounted.add(mp.supplied).add(fixedDepositPositions[1])).to.eq(
                    parseUnits("100010125"),
                  );
                });
              });
              describe("AND GIVEN a partial withdrawMP of half amount deposited + half earned fees", () => {
                beforeEach(async () => {
                  withdrawAmount = 50005062.5; // 5k + 50M + 62.5 earned fees

                  await fixedLenderEnv.withdrawMP(nextPoolID, withdrawAmount.toString());

                  mp = await fixedLenderHarness.fixedPools(nextPoolID);
                  returnValues = await fixedLenderHarness.returnValues();
                  fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
                });
                it("THEN the maturity pool state is correctly updated", async () => {
                  expect(mp.borrowed).to.eq(parseUnits("0"));
                  expect(mp.supplied).to.eq(parseUnits("50005000"));
                });
                it("THEN earningsUnassigned are still 0", async () => {
                  expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
                });
                it("THEN the earningsSP returned are 0", async () => {
                  expect(returnValues.earningsSP).to.eq(parseUnits("0"));
                });
                it("THEN the redeemAmountDiscounted returned is equal to the amount withdrawn", async () => {
                  expect(returnValues.redeemAmountDiscounted).to.eq(parseUnits(withdrawAmount.toString()));
                });
                describe("AND GIVEN a borrow of 100k that leaves the pool without enough liquidity", () => {
                  beforeEach(async () => {
                    await fixedLenderEnv.borrowMP(nextPoolID, "100000");
                  });
                  it("THEN the smartPoolEarningsAccumulator accrues 5000 more (5% borrow bc uses mp deposits)", async () => {
                    expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.eq(parseUnits("5500"));
                  });
                  describe("AND GIVEN the other half amount deposited + half earned fees is withdrawn", () => {
                    beforeEach(async () => {
                      withdrawAmount = 50005062.5; // 5k + 50M + 62.5 earned fees

                      await fixedLenderEnv.withdrawMP(nextPoolID, withdrawAmount.toString());

                      mp = await fixedLenderHarness.fixedPools(nextPoolID);
                      returnValues = await fixedLenderHarness.returnValues();
                      fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
                    });
                    it("THEN the maturity pool state is correctly updated", async () => {
                      expect(mp.borrowed).to.eq(parseUnits("100000")); // 100k borrowed
                      expect(mp.supplied).to.eq(parseUnits("0"));
                    });
                    it("THEN the smartPoolBorrowed is equal to 100k", async () => {
                      expect(await fixedLenderHarness.smartPoolBorrowed()).to.eq(parseUnits("100000"));
                    });
                    it("THEN earningsUnassigned are still 0", async () => {
                      expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
                    });
                    it("THEN the earningsSP returned are 0", async () => {
                      expect(returnValues.earningsSP).to.eq(parseUnits("0"));
                    });
                    it("THEN the smartPoolEarningsAccumulator are still 5500", async () => {
                      expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.eq(parseUnits("5500"));
                    });
                    it("THEN the redeemAmountDiscounted returned is equal to the amount withdrawn", async () => {
                      expect(returnValues.redeemAmountDiscounted).to.eq(parseUnits(withdrawAmount.toString()));
                    });
                  });
                });
              });
              describe("AND GIVEN a total withdrawMP of the total amount deposited + earned fees", () => {
                beforeEach(async () => {
                  withdrawAmount = 100010125; // 10k + 100M + 125 earned fees

                  await fixedLenderEnv.withdrawMP(nextPoolID, withdrawAmount.toString());

                  mp = await fixedLenderHarness.fixedPools(nextPoolID);
                  returnValues = await fixedLenderHarness.returnValues();
                  fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
                });
                it("THEN the maturity pool state is correctly updated", async () => {
                  expect(mp.borrowed).to.eq(parseUnits("0"));
                  expect(mp.supplied).to.eq(parseUnits("0"));
                });
                it("THEN earningsUnassigned are still 0", async () => {
                  expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
                });
                it("THEN the earningsSP returned are 0", async () => {
                  expect(returnValues.earningsSP).to.eq(parseUnits("0"));
                });
                it("THEN the redeemAmountDiscounted returned is equal to all amount withdrawn", async () => {
                  expect(returnValues.redeemAmountDiscounted).to.eq(parseUnits(withdrawAmount.toString()));
                });
              });
            });

            describe("AND GIVEN a partial repayMP at maturity(+1 DAY) with an amount of 8000 (partial late repayment)", () => {
              let mp: any;
              beforeEach(async () => {
                await fixedLenderHarness.setFreePenaltyRate(parseUnits("0.1").div(86_400));

                await fixedLenderEnv.moveInTime(nextPoolID + 86_400);
                repayAmount = 8000;
                await fixedLenderEnv.repayMP(nextPoolID, repayAmount.toString(), "9000");
                returnValues = await fixedLenderHarness.returnValues();
                mp = await fixedLenderHarness.fixedPools(nextPoolID);
                fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
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
                expect(returnValues.debtCovered).to.equal(parseUnits("8000"));
              });
              it("THEN smartPoolEarningsAccumulator receives the 10% of penalties", async () => {
                expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.gt(parseUnits("1299.999"));
                expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.lt(parseUnits("1300"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                expect(returnValues.earningsSP).to.eq(0);
              });

              afterEach(async () => {
                await fixedLenderHarness.setFreePenaltyRate(0);
              });
            });

            describe("AND GIVEN a repayMP at maturity(+1 DAY) with an amount of 15750*1.1=17325 (total late repayment)", () => {
              let mp: any;
              beforeEach(async () => {
                await fixedLenderHarness.setFreePenaltyRate(parseUnits("0.1").div(86_400));

                await fixedLenderEnv.moveInTime(nextPoolID + 86_400);
                repayAmount = 17325;
                await fixedLenderEnv.repayMP(nextPoolID, repayAmount.toString());
                returnValues = await fixedLenderHarness.returnValues();
                fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
                mp = await fixedLenderHarness.fixedPools(nextPoolID);
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
                expect(returnValues.debtCovered).to.eq(parseUnits("15750"));
              });
              it("THEN smartPoolEarningsAccumulator receives 10% of penalties", async () => {
                // 17325 - 15750 = 1575 (10% of the debt)
                // + 500 previous earnings
                expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.gt(parseUnits("2074"));
                expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.lt(parseUnits("2075"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                expect(returnValues.earningsSP).to.eq(0);
              });
              it("THEN the actualRepayAmount returned is almost 17325", async () => {
                expect(returnValues.actualRepayAmount).to.lt(parseUnits(repayAmount.toString()));
                expect(returnValues.actualRepayAmount).to.gt(parseUnits((repayAmount - 0.1).toString()));
              });
            });

            describe("AND GIVEN a repayMP at maturity(+1 DAY) with an amount of 2000 on a debt 15750*0.1=17325 (way more money late repayment)", () => {
              let mp: any;
              beforeEach(async () => {
                await fixedLenderHarness.setFreePenaltyRate(parseUnits("0.1").div(86_400));

                await fixedLenderEnv.moveInTime(nextPoolID + 86_400);
                repayAmount = 20000;
                await fixedLenderEnv.repayMP(nextPoolID, repayAmount.toString());
                returnValues = await fixedLenderHarness.returnValues();
                fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
                mp = await fixedLenderHarness.fixedPools(nextPoolID);
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
                expect(returnValues.debtCovered).to.eq(parseUnits("15750"));
              });
              it("THEN smartPoolEarningsAccumulator receive the 10% of penalties", async () => {
                // 17325 - 15750 = 1575 (10% of the debt)
                // + 500 previous earnings
                expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.gt(parseUnits("2074"));
                expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.lt(parseUnits("2075"));
              });
              it("THEN the earningsSP returned are 0", async () => {
                expect(returnValues.earningsSP).to.eq(0);
              });
              it("THEN the actualRepayAmount returned is ~= 17325 (paid 20000 on a 17325 debt)", async () => {
                expect(returnValues.actualRepayAmount).to.be.gt(parseUnits("17324.9"));
                expect(returnValues.actualRepayAmount).to.be.lt(parseUnits("17325"));
              });
            });
          });
        });
      });
    });
  });

  describe("Smart Pool Reserve", () => {
    describe("GIVEN a sp total supply of 100, a 10% smart pool reserve and a borrow for 80", () => {
      let tx: any;
      beforeEach(async () => {
        fixedLenderEnv.switchWallet(laura);
        await fixedLenderEnv.setSmartPoolAssets(parseUnits("100"));
        await fixedLenderHarness.setSmartPoolReserveFactor(parseUnits("0.1"));
        tx = fixedLenderEnv.borrowMP(nextPoolID, "80");
        await tx;
      });
      it("THEN the borrow transaction should not revert", async () => {
        await expect(tx).to.not.be.reverted;
      });
      it("AND WHEN trying to borrow 10 more, THEN it should not revert", async () => {
        await expect(fixedLenderEnv.borrowMP(nextPoolID, "10")).to.not.be.reverted;
      });
      it("AND WHEN trying to borrow 10.01 more, THEN it should revert with SmartPoolReserveExceeded", async () => {
        await expect(fixedLenderEnv.borrowMP(nextPoolID, "10.01")).to.be.revertedWith("SmartPoolReserveExceeded()");
      });
      it("AND WHEN depositing 0.1 more to the sp, THEN it should not revert when trying to borrow 10.01 more", async () => {
        await fixedLenderEnv.setSmartPoolAssets(parseUnits("100.1"));
        await expect(fixedLenderEnv.borrowMP(nextPoolID, "10.01")).to.not.be.reverted;
      });
      it("AND WHEN setting the smart pool reserve to 0, THEN it should not revert when trying to borrow 10.01 more", async () => {
        await fixedLenderHarness.setSmartPoolReserveFactor(0);
        await expect(fixedLenderEnv.borrowMP(nextPoolID, "10.01")).to.not.be.reverted;
      });
      it("AND WHEN setting the smart pool reserve to 0, THEN it should not revert when trying to borrow all supply left (20)", async () => {
        await fixedLenderHarness.setSmartPoolReserveFactor(0);
        await expect(fixedLenderEnv.borrowMP(nextPoolID, "20")).to.not.be.reverted;
      });
      describe("AND GIVEN a deposit of 10 to the maturity pool", () => {
        beforeEach(async () => {
          await fixedLenderEnv.depositMP(nextPoolID, "10");
        });
        it("AND WHEN trying to borrow 20 more, THEN it should not revert", async () => {
          await expect(fixedLenderEnv.borrowMP(nextPoolID, "20")).to.not.be.reverted;
        });
        describe("AND GIVEN a borrow of 10 to the maturity pool AND a withdraw of 10", () => {
          beforeEach(async () => {
            await fixedLenderEnv.borrowMP(nextPoolID, "10");
            tx = fixedLenderEnv.withdrawMP(nextPoolID, "10");
            await tx;
          });
          it("THEN the withdraw transaction should not revert", async () => {
            await expect(tx).to.not.be.reverted;
          });
          it("AND WHEN trying to borrow 0.01 more, THEN it should revert with SmartPoolReserveExceeded", async () => {
            await expect(fixedLenderEnv.borrowMP(nextPoolID, "0.01")).to.be.revertedWith("SmartPoolReserveExceeded()");
          });
          describe("AND GIVEN a repay of 5", () => {
            beforeEach(async () => {
              await fixedLenderEnv.repayMP(nextPoolID, "5");
            });
            it("WHEN trying to borrow 5 more, THEN it should not revert", async () => {
              await expect(fixedLenderEnv.borrowMP(nextPoolID, "5")).to.not.be.reverted;
            });
            it("AND WHEN trying to borrow 5.01 more, THEN it should revert with SmartPoolReserveExceeded", async () => {
              await expect(fixedLenderEnv.borrowMP(nextPoolID, "5.01")).to.be.revertedWith(
                "SmartPoolReserveExceeded()",
              );
            });
          });
        });
      });
    });
  });

  describe("Assignment of earnings over time", () => {
    describe("GIVEN a borrowMP of 10000 (600 fees owed by user) - 24 days to maturity", () => {
      let returnValues: any;
      let mp: any;
      const twentyFourDaysToMaturity = nextPoolID - 86_400 * 24;
      const twentyDaysToMaturity = nextPoolID - 86_400 * 20;
      const sixteenDaysToMaturity = nextPoolID - 86_400 * 16;
      const twelveDaysToMaturity = nextPoolID - 86_400 * 12;
      const eightDaysToMaturity = nextPoolID - 86_400 * 8;
      const fourDaysToMaturity = nextPoolID - 86_400 * 4;

      beforeEach(async () => {
        fixedLenderEnv.switchWallet(laura);
        await mockInterestRateModel.setBorrowRate(parseUnits("0.06"));
        await fixedLenderEnv.moveInTime(twentyFourDaysToMaturity);
        await fixedLenderEnv.borrowMP(nextPoolID, "10000");
      });
      describe("AND GIVEN a depositMP of 1000 (50 fees earned by user) - 20 days to maturity", () => {
        beforeEach(async () => {
          await fixedLenderEnv.moveInTime(twentyDaysToMaturity);
          await fixedLenderEnv.depositMP(nextPoolID, "1000");
          mp = await fixedLenderHarness.fixedPools(nextPoolID);
          returnValues = await fixedLenderHarness.returnValues();
        });
        it("THEN earningsUnassigned should be 360", () => {
          expect(mp.earningsUnassigned).to.eq(parseUnits("450")); // 600 - 100 (earningsSP) - 50 (earnings MP depositor)
        });
        it("THEN the earningsSP returned are 100", async () => {
          expect(returnValues.earningsSP).to.eq(parseUnits("100")); // 1 day passed
        });
        it("THEN the currentTotalDeposit returned is 1050", async () => {
          expect(returnValues.currentTotalDeposit).to.eq(parseUnits("1050"));
        });
        describe("AND GIVEN a withdraw of 1050 - 16 days to maturity", () => {
          beforeEach(async () => {
            await mockInterestRateModel.setBorrowRate(parseUnits("0.05"));
            await fixedLenderEnv.moveInTime(sixteenDaysToMaturity);
            await fixedLenderEnv.withdrawMP(nextPoolID, "1050", "1000");
            mp = await fixedLenderHarness.fixedPools(nextPoolID);
            returnValues = await fixedLenderHarness.returnValues();
          });
          it("THEN earningsUnassigned should be 410", () => {
            expect(mp.earningsUnassigned).to.eq(parseUnits("410")); // 450 - 90 + 50
          });
          it("THEN the earningsSP returned are 90", async () => {
            expect(returnValues.earningsSP).to.eq(parseUnits("90")); // 450 / 5
          });
          describe("AND GIVEN another borrowMP of 10000 (601.5 fees owed by user) - 12 days to maturity", () => {
            beforeEach(async () => {
              await mockInterestRateModel.setBorrowRate(parseUnits("0.06015"));
              await fixedLenderEnv.moveInTime(twelveDaysToMaturity);
              await fixedLenderEnv.borrowMP(nextPoolID, "10000");
              mp = await fixedLenderHarness.fixedPools(nextPoolID);
              returnValues = await fixedLenderHarness.returnValues();
            });
            it("THEN earningsUnassigned should be 909", () => {
              expect(mp.earningsUnassigned).to.eq(parseUnits("909")); // 410 - 102.5 (410 / 4) + 601.5
            });
            it("THEN the earningsSP returned are 102.5", async () => {
              expect(returnValues.earningsSP).to.eq(parseUnits("102.5")); // (410 / 4)
            });
            it("THEN the totalOwedNewBorrow returned is 10601.5", async () => {
              expect(returnValues.totalOwedNewBorrow).to.eq(parseUnits("10601.5"));
            });
            describe("AND GIVEN a repayMP of 10600.75 (half of borrowed) - 8 days to maturity", () => {
              beforeEach(async () => {
                await fixedLenderEnv.moveInTime(eightDaysToMaturity);
                await fixedLenderEnv.repayMP(nextPoolID, "10600.75");
                mp = await fixedLenderHarness.fixedPools(nextPoolID);
                returnValues = await fixedLenderHarness.returnValues();
              });
              it("THEN earningsUnassigned should be 303", () => {
                expect(mp.earningsUnassigned).to.eq(parseUnits("303"));
              });
              it("THEN the earningsSP returned are 303", async () => {
                expect(returnValues.earningsSP).to.eq(parseUnits("303")); // 909 / 3
              });
              it("THEN the actualRepayAmount returned is 10600.75 - 303", async () => {
                expect(returnValues.actualRepayAmount).to.eq(
                  parseUnits("10297.75"), // 10600.75 - (909 - 303) / 2
                );
              });
              it("THEN the debtCovered returned is 10600.75", async () => {
                expect(returnValues.debtCovered).to.eq(parseUnits("10600.75"));
              });
              describe("AND GIVEN a repayMP of the other half (10600.75) - 4 days to maturity", () => {
                beforeEach(async () => {
                  await fixedLenderEnv.moveInTime(fourDaysToMaturity);
                  await fixedLenderEnv.repayMP(nextPoolID, "10600.75");
                  mp = await fixedLenderHarness.fixedPools(nextPoolID);
                  returnValues = await fixedLenderHarness.returnValues();
                });
                it("THEN earningsUnassigned should be 0", () => {
                  expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
                });
                it("THEN the earningsSP returned are 151.5", async () => {
                  expect(returnValues.earningsSP).to.eq(parseUnits("151.5")); // 303 / 2
                });
                it("THEN the actualRepayAmount returned is 10600.75 - 151.5", async () => {
                  expect(returnValues.actualRepayAmount).to.eq(parseUnits("10449.25"));
                });
                it("THEN the debtCovered returned is 10600.75", async () => {
                  expect(returnValues.debtCovered).to.eq(parseUnits("10600.75"));
                });
              });
            });
          });
        });
      });
    });
  });

  describe("Early Withdrawal / Early Repayment", () => {
    let returnValues: any;
    let mp: any;
    let borrowAmount: number;
    let fixedPoolState: FixedPoolState;
    const fiveDaysToMaturity = nextPoolID - 86_400 * 5;
    const fourDaysToMaturity = nextPoolID - 86_400 * 4;
    const threeDaysToMaturity = nextPoolID - 86_400 * 3;

    beforeEach(async () => {
      fixedPoolState = {
        borrowFees: parseUnits("0"),
        earningsUnassigned: parseUnits("0"),
        earningsAccumulator: parseUnits("0"),
        earningsSP: parseUnits("0"),
        earningsMP: parseUnits("0"),
        earningsDiscounted: parseUnits("0"),
      };
    });

    describe("GIVEN an empty SP AND a deposit of 100", () => {
      beforeEach(async () => {
        await fixedLenderEnv.setSmartPoolAssets(parseUnits("0"));
        await fixedLenderEnv.depositMP(nextPoolID, "100");
      });

      it("THEN it should not revert when trying to withdraw early previous 100 deposited", async () => {
        await expect(fixedLenderEnv.withdrawMP(nextPoolID, "100", "90")).to.not.be.reverted;
      });
    });

    describe("GIVEN a borrowMP of 10000 (500 fees owed by user)", () => {
      beforeEach(async () => {
        borrowAmount = 10000;
        fixedLenderEnv.switchWallet(laura);
        await mockInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await fixedLenderEnv.moveInTime(fiveDaysToMaturity);
        await fixedLenderEnv.borrowMP(nextPoolID, borrowAmount.toString());

        mp = await fixedLenderHarness.fixedPools(nextPoolID);
        returnValues = await fixedLenderHarness.returnValues();
        fixedPoolState.borrowFees = returnValues.totalOwedNewBorrow.sub(parseUnits(borrowAmount.toString()));
      });

      it("THEN all earningsUnassigned should be 500", () => {
        expect(mp.earningsUnassigned).to.eq(parseUnits("500"));
      });

      describe("WHEN an early repayment of 5250", () => {
        beforeEach(async () => {
          await fixedLenderEnv.moveInTime(fourDaysToMaturity);
          await fixedLenderEnv.repayMP(nextPoolID, "5250");
          returnValues = await fixedLenderHarness.returnValues();
          mp = await fixedLenderHarness.fixedPools(nextPoolID);
          fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
          fixedPoolState.earningsDiscounted = parseUnits("5250").sub(returnValues.actualRepayAmount);
        });
        it("THEN borrowed is 5000", async () => {
          expect(mp.borrowed).to.eq(parseUnits("5000"));
        });
        it("THEN all earningsUnassigned should be 200", async () => {
          // 200 = 500 original - 100 accrued - 200 discount
          expect(mp.earningsUnassigned).to.eq(parseUnits("200"));
        });
        it("THEN the debtCovered returned is 5250", async () => {
          expect(returnValues.debtCovered).eq(parseUnits("5250"));
        });
        it("THEN the earningsSP returned are 100", async () => {
          expect(returnValues.earningsSP).eq(parseUnits("100")); // =1/5th of 500 since one day went by
        });
        it("THEN the actualRepayAmount returned is 5000 (got a 200 discount)", async () => {
          expect(returnValues.actualRepayAmount).to.eq(parseUnits("5050"));
        });

        describe("AND WHEN an early repayment of 5250", () => {
          beforeEach(async () => {
            await fixedLenderEnv.moveInTime(threeDaysToMaturity);
            await fixedLenderEnv.repayMP(nextPoolID, "5250");
            returnValues = await fixedLenderHarness.returnValues();
            mp = await fixedLenderHarness.fixedPools(nextPoolID);
            fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
            fixedPoolState.earningsDiscounted = fixedPoolState.earningsDiscounted.add(
              parseUnits("5250").sub(returnValues.actualRepayAmount),
            );
          });
          it("THEN borrowed is 0", async () => {
            expect(mp.borrowed).to.eq(0);
          });
          it("THEN supplied is 0", async () => {
            expect(mp.supplied).to.eq(0);
          });
          it("THEN all earningsUnassigned should be 0", async () => {
            expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
          });
          it("THEN the debtCovered returned is 5250", async () => {
            expect(returnValues.debtCovered).eq(parseUnits("5250"));
          });
          it("THEN the earningsSP returned are 50", async () => {
            expect(returnValues.earningsSP).eq(parseUnits("50")); // 1 day passed (1/5) since last accrual
          });
          it("THEN the actualRepayAmount returned is 5000 (got a 150 discount)", async () => {
            expect(returnValues.actualRepayAmount).to.eq(parseUnits("5100"));
          });
          it("THEN the borrow fees are equal to all earnings distributed", async () => {
            expect(fixedPoolState.borrowFees).to.eq(fixedLenderEnv.getAllEarnings(fixedPoolState));
          });
        });
        describe("AND WHEN an early repayment of 5250 with a spFeeRate of 10%", () => {
          beforeEach(async () => {
            await mockInterestRateModel.setSPFeeRate(parseUnits("0.1"));
            await fixedLenderEnv.moveInTime(threeDaysToMaturity);
            await fixedLenderEnv.repayMP(nextPoolID, "5250");
            returnValues = await fixedLenderHarness.returnValues();
            mp = await fixedLenderHarness.fixedPools(nextPoolID);
            fixedPoolState.earningsSP = fixedPoolState.earningsSP.add(returnValues.earningsSP);
            fixedPoolState.earningsAccumulator = await fixedLenderHarness.smartPoolEarningsAccumulator();
            fixedPoolState.earningsDiscounted = fixedPoolState.earningsDiscounted.add(
              parseUnits("5250").sub(returnValues.actualRepayAmount),
            );
          });
          it("THEN borrowed is 0", async () => {
            expect(mp.borrowed).to.eq(0);
          });
          it("THEN supplied is 0", async () => {
            expect(mp.supplied).to.eq(0);
          });
          it("THEN all earningsUnassigned should be 0", async () => {
            expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
          });
          it("THEN the debtCovered returned is 5250", async () => {
            expect(returnValues.debtCovered).eq(parseUnits("5250"));
          });
          it("THEN the earningsSP returned are 50 accrued", async () => {
            expect(returnValues.earningsSP).eq(parseUnits("50"));
          });
          it("THEN the smartPoolEarningsAccumulator are 15 (10% spFeeRate)", async () => {
            expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).to.eq(parseUnits("15"));
          });
          it("THEN the actualRepayAmount returned is 5115 = 5250 - earningsSP(t-1)(are 50) - earningsSP(t)(are 50) - accumulator(t)(are 15)", async () => {
            expect(returnValues.actualRepayAmount).to.eq(parseUnits("5115"));
          });
          it("THEN the borrow fees are equal to all earnings distributed", async () => {
            expect(fixedPoolState.borrowFees).to.eq(fixedLenderEnv.getAllEarnings(fixedPoolState));
          });
        });
      });
    });

    describe("GIVEN a borrowMP of 5000 (250 fees owed by user) AND a depositMP of 5000 (earns 250 in fees)", () => {
      beforeEach(async () => {
        borrowAmount = 5000;
        fixedLenderEnv.switchWallet(laura);
        await mockInterestRateModel.setBorrowRate(parseUnits("0.05"));
        await fixedLenderEnv.moveInTime(fiveDaysToMaturity);
        await fixedLenderEnv.borrowMP(nextPoolID, borrowAmount.toString());
        await fixedLenderEnv.moveInTime(fourDaysToMaturity);
        await fixedLenderEnv.depositMP(nextPoolID, "5000");

        returnValues = await fixedLenderHarness.returnValues();
        mp = await fixedLenderHarness.fixedPools(nextPoolID);
        fixedPoolState.earningsMP = returnValues.currentTotalDeposit.sub(parseUnits("5000"));
        fixedPoolState.borrowFees = returnValues.totalOwedNewBorrow.sub(parseUnits(borrowAmount.toString()));
        fixedPoolState.earningsDiscounted = parseUnits("0");
        fixedPoolState.earningsSP = returnValues.earningsSP.add(fixedPoolState.earningsSP);
      });
      it("THEN all earningsUnassigned should be 0", async () => {
        expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
      });
      it("THEN the earningsSP returned are 50", async () => {
        expect(returnValues.earningsSP).eq(parseUnits("50"));
      });
      it("THEN the currentTotalDeposit returned is 5000 + 200 (earned fees)", async () => {
        expect(returnValues.currentTotalDeposit).eq(parseUnits("5200"));
      });

      describe("WHEN an early repayment of 5250", () => {
        beforeEach(async () => {
          await fixedLenderEnv.repayMP(nextPoolID, "5250");
          returnValues = await fixedLenderHarness.returnValues();
          mp = await fixedLenderHarness.fixedPools(nextPoolID);
          fixedPoolState.earningsSP = returnValues.earningsSP.add(fixedPoolState.earningsSP);
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
        it("THEN the actualRepayAmount returned is 5250 (didn't get a discount since it was gotten all before)", async () => {
          expect(returnValues.actualRepayAmount).to.eq(parseUnits("5250"));
        });
        it("THEN the borrow fees are equal to all earnings distributed", async () => {
          expect(fixedPoolState.borrowFees).to.eq(fixedLenderEnv.getAllEarnings(fixedPoolState));
        });
      });

      describe("WHEN an early withdrawal of 5250 without enough slippage", () => {
        let tx: any;
        beforeEach(async () => {
          tx = fixedLenderEnv.withdrawMP(nextPoolID, "5250", "5250");
        });
        it("THEN it should revert with error TOO_MUCH_SLIPPAGE", async () => {
          await expect(tx).to.be.revertedWith("TooMuchSlippage()");
        });
      });

      describe("WHEN an early withdrawal of 5250 (deposited + fees) and a borrow rate shoots to 10%", () => {
        beforeEach(async () => {
          await mockInterestRateModel.setBorrowRate(parseUnits("0.1"));
          await fixedLenderEnv.withdrawMP(nextPoolID, "5250", "4500");
          returnValues = await fixedLenderHarness.returnValues();
          mp = await fixedLenderHarness.fixedPools(nextPoolID);
        });
        it("THEN borrowed is 5000", async () => {
          // 4772.72 is the real value that the smart pool needed to cover
          // but for simplicity it will cover the full 5000
          // the difference between 4772.72 and 5000 is the amount we added to the unassigned earnings due to the high borrow rate when withdrawing
          expect(mp.borrowed).to.eq(parseUnits("5000"));
        });
        it("THEN earningsUnassigned should be 477 (250 + money left on the table)", async () => {
          expect(mp.earningsUnassigned).to.eq(parseUnits("472.727272727272727273"));
        });
        it("THEN supplied should be 0", async () => {
          expect(mp.supplied).to.eq(parseUnits("0"));
        });
        it("THEN the redeemAmountDiscounted returned is 4772", async () => {
          // 5250 / 1.10 (1e18 + 1e17 feeRate) = 4772.72727272727272727272
          expect(returnValues.redeemAmountDiscounted).to.be.eq(parseUnits("4727.272727272727272727"));
        });
        it("THEN the earningsSP returned is 0", async () => {
          expect(returnValues.earningsSP).eq(parseUnits("0"));
        });
        it("THEN the fixedDepositPositions is 0", async () => {
          const fixedDepositPositions = await fixedLenderHarness.fixedDepositPositions(nextPoolID, laura.address);

          expect(fixedDepositPositions[0]).to.be.eq(parseUnits("0"));
          expect(fixedDepositPositions[1]).to.be.eq(parseUnits("0"));
        });
      });

      describe("WHEN an early withdrawal of 5200 (deposited + fees)", () => {
        beforeEach(async () => {
          await fixedLenderEnv.withdrawMP(nextPoolID, "5200", "4500");
          returnValues = await fixedLenderHarness.returnValues();
          mp = await fixedLenderHarness.fixedPools(nextPoolID);
        });
        it("THEN borrowed is 0", async () => {
          expect(mp.borrowed).to.eq(parseUnits("5000"));
        });
        it("THEN earningsUnassigned should be 250 again", async () => {
          // 5200 / 1.05 = 4952;
          // 5200 - 4952 = ~248;
          expect(mp.earningsUnassigned).to.eq(parseUnits("247.619047619047619048"));
        });
        it("THEN the redeemAmountDiscounted returned is 5000", async () => {
          // 5200 / 1.05 (1e18 + 5e16 feeRate) = 4952
          expect(returnValues.redeemAmountDiscounted).to.be.eq(parseUnits("4952.380952380952380952"));
        });
        it("THEN the earningsSP returned is 0", async () => {
          expect(returnValues.earningsSP).eq(parseUnits("0"));
        });
        it("THEN the fixedDepositPositions is 0", async () => {
          const fixedDepositPositions = await fixedLenderHarness.fixedDepositPositions(nextPoolID, laura.address);

          expect(fixedDepositPositions[0]).to.be.eq(parseUnits("0"));
          expect(fixedDepositPositions[1]).to.be.eq(parseUnits("0"));
        });
      });
      describe("AND GIVEN a deposit of 5250", () => {
        beforeEach(async () => {
          await fixedLenderEnv.depositMP(nextPoolID, "5250");
        });
        describe("WHEN an early withdrawal of 5250 (deposited + fees)", () => {
          beforeEach(async () => {
            await fixedLenderEnv.withdrawMP(nextPoolID, "5250", "4500");
            returnValues = await fixedLenderHarness.returnValues();
            mp = await fixedLenderHarness.fixedPools(nextPoolID);
          });
          it("THEN earningsUnassigned is 0", async () => {
            expect(mp.earningsUnassigned).to.eq(parseUnits("0"));
          });
          it("THEN the earningsSP returned is 0", async () => {
            expect(returnValues.earningsSP).eq(parseUnits("0"));
          });
          it("THEN the smartPoolEarningsAccumulator returned is 250", async () => {
            expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).eq(parseUnits("250"));
          });
        });
      });
      describe("AND GIVEN a deposit of 2625", () => {
        beforeEach(async () => {
          await fixedLenderEnv.depositMP(nextPoolID, "2625");
        });
        describe("WHEN an early withdrawal of 5250 (deposited + fees)", () => {
          beforeEach(async () => {
            await fixedLenderEnv.withdrawMP(nextPoolID, "5250", "4500");
            returnValues = await fixedLenderHarness.returnValues();
            mp = await fixedLenderHarness.fixedPools(nextPoolID);
          });
          it("THEN earningsUnassigned is 125", async () => {
            expect(mp.earningsUnassigned).to.eq(parseUnits("124.540734824281150160"));
          });
          it("THEN the earningsSP returned is 0", async () => {
            expect(returnValues.earningsSP).eq(parseUnits("0"));
          });
          it("THEN the smartPoolEarningsAccumulator returned is 125", async () => {
            expect(await fixedLenderHarness.smartPoolEarningsAccumulator()).eq(parseUnits("125.459265175718849840"));
          });
        });
      });
    });

    describe("User receives more money than deposited for repaying earlier", () => {
      describe("GIVEN a borrowMP of 10000 (500 fees owed by user) (5 days to maturity)", () => {
        beforeEach(async () => {
          fixedLenderEnv.switchWallet(laura);
          await mockInterestRateModel.setBorrowRate(parseUnits("0.05"));
          await fixedLenderEnv.moveInTime(fiveDaysToMaturity);
          await fixedLenderEnv.borrowMP(nextPoolID, "10000");
          mp = await fixedLenderHarness.fixedPools(nextPoolID);
        });

        it("THEN all earningsUnassigned should be 500", () => {
          expect(mp.earningsUnassigned).to.eq(parseUnits("500"));
        });

        describe("GIVEN a borrowMP of 10000 (10000 fees owed by user) (4 days to maturity)", () => {
          beforeEach(async () => {
            fixedLenderEnv.switchWallet(tina);
            await mockInterestRateModel.setBorrowRate(parseUnits("1")); // Crazy FEE
            await fixedLenderEnv.moveInTime(fourDaysToMaturity);
            await fixedLenderEnv.borrowMP(nextPoolID, "10000", "20000"); // ... and we accept it
            mp = await fixedLenderHarness.fixedPools(nextPoolID);
          });

          it("THEN all earningsUnassigned should be 10500", async () => {
            // 100 out of 500 accrued because 1 day went by for the original 500
            expect(mp.earningsUnassigned).to.eq(parseUnits("10400"));
          });

          describe("WHEN an early repayment of 10500 (3 days to maturity)", () => {
            beforeEach(async () => {
              fixedLenderEnv.switchWallet(laura);
              await fixedLenderEnv.moveInTime(threeDaysToMaturity);
              await fixedLenderEnv.repayMP(nextPoolID, "10500");
              returnValues = await fixedLenderHarness.returnValues();
              mp = await fixedLenderHarness.fixedPools(nextPoolID);
            });
            it("THEN borrowed is 10000", async () => {
              expect(mp.borrowed).to.eq(parseUnits("10000"));
            });
            it("THEN all earningsUnassigned should be 3900", async () => {
              // 10400 * .75 = 7800 => unassigned before operation after accrual (1 out of 4 days went by)
              // 7800 / 2 = 3900 => covering half sp debt gives half of the unassigned
              expect(mp.earningsUnassigned).to.eq(parseUnits("3900"));
            });
            it("THEN the debtCovered returned is 10500", async () => {
              expect(returnValues.debtCovered).eq(parseUnits("10500"));
            });
            it("THEN the earningsSP returned are 0", async () => {
              // 10400 * .25 = 2600 => (1 out of 4 days went by)
              expect(returnValues.earningsSP).eq(parseUnits("2600"));
            });
            it("THEN the actualRepayAmount returned is 6600 (got a 3900 discount)", async () => {
              // Repaying 10500 minus 3900 for the half taken from unassigned earnings
              expect(returnValues.actualRepayAmount).to.eq(parseUnits("6600"));
            });
          });
        });
      });
    });
  });

  describe("Operations in more than one pool", () => {
    describe("GIVEN a smart pool supply of 100 AND a borrow of 30 in a first maturity pool", () => {
      const secondPoolID = nextPoolID + INTERVAL;

      beforeEach(async () => {
        fixedLenderEnv.switchWallet(laura);
        await fixedLenderEnv.setSmartPoolAssets(parseUnits("100"));
        await fixedLenderEnv.borrowMP(nextPoolID, "30");
      });
      it("WHEN a borrow of 70 is made to the second mp, THEN it should not revert", async () => {
        await expect(fixedLenderEnv.borrowMP(secondPoolID, "70")).to.not.be.reverted;
      });
      it("WHEN a borrow of 70.01 is made to the second mp, THEN it should fail with error InsufficientProtocolLiquidity", async () => {
        await expect(fixedLenderEnv.borrowMP(secondPoolID, "70.01")).to.be.revertedWith(
          "InsufficientProtocolLiquidity()",
        );
      });
      describe("AND GIVEN a deposit to the first mp of 30 AND a borrow of 70 in the second mp", () => {
        beforeEach(async () => {
          await fixedLenderEnv.depositMP(nextPoolID, "30");
          await fixedLenderEnv.borrowMP(secondPoolID, "70");
        });
        it("WHEN a borrow of 30 is made to the first mp, THEN it should not revert", async () => {
          await expect(fixedLenderEnv.borrowMP(nextPoolID, "30")).to.not.be.reverted;
        });
        it("WHEN a borrow of 30.01 is made to the first mp, THEN it should fail with error InsufficientProtocolLiquidity", async () => {
          await expect(fixedLenderEnv.borrowMP(secondPoolID, "31")).to.be.revertedWith(
            "InsufficientProtocolLiquidity()",
          );
        });
        describe("AND GIVEN a borrow of 30 in the first mp", () => {
          beforeEach(async () => {
            await fixedLenderEnv.borrowMP(nextPoolID, "30");
          });
          it("WHEN a withdraw of 30 is made to the first mp, THEN it should revert", async () => {
            await expect(fixedLenderEnv.withdrawMP(nextPoolID, "30")).to.be.revertedWith(
              "InsufficientProtocolLiquidity()",
            );
          });
          it("AND WHEN a supply of 30 is added to the sp, THEN the withdraw of 30 is not reverted", async () => {
            await fixedLenderEnv.setSmartPoolAssets(parseUnits("130"));
            await expect(fixedLenderEnv.withdrawMP(nextPoolID, "30")).to.not.be.reverted;
          });
          it("AND WHEN a deposit of 30 is added to the mp, THEN the withdraw of 30 is not reverted", async () => {
            await fixedLenderEnv.depositMP(nextPoolID, "30");
            await expect(fixedLenderEnv.withdrawMP(nextPoolID, "30")).to.not.be.reverted;
          });
        });
      });
    });
  });

  afterEach(async () => {
    await provider.send("evm_revert", [snapshot]);
  });
});