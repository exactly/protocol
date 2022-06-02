import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { errorUnmatchedPool, PoolState } from "./exactlyUtils";
import { DefaultEnv } from "./defaultEnv";
import futurePools, { INTERVAL } from "./utils/futurePools";

const nextPoolId = futurePools(1)[0].toNumber();

describe("Validations", function () {
  let auditor: Contract;
  let fixedLender: Contract;
  let interestRateModel: Contract;
  let exactlyEnv: DefaultEnv;

  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  before(async () => {
    [owner, user] = await ethers.getSigners();

    exactlyEnv = await DefaultEnv.create({ useRealInterestRateModel: true });
    auditor = exactlyEnv.auditor;
    interestRateModel = exactlyEnv.interestRateModel;
    fixedLender = exactlyEnv.getFixedLender("DAI");
  });

  describe("Auditor: GIVEN an unlisted market as parameter", () => {
    it("WHEN trying to enter markets, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(auditor.enterMarket(exactlyEnv.notAnFixedLenderAddress)).to.be.revertedWith("MarketNotListed()");
    });
    it("WHEN trying to exit market, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(auditor.exitMarket(exactlyEnv.notAnFixedLenderAddress)).to.be.revertedWith("MarketNotListed()");
    });
    it("WHEN trying to call validateBorrowMP, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(auditor.validateBorrowMP(exactlyEnv.notAnFixedLenderAddress, owner.address)).to.be.revertedWith(
        "MarketNotListed()",
      );
    });
    it("WHEN trying to set borrow caps, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(
        auditor.setMarketBorrowCaps([exactlyEnv.notAnFixedLenderAddress], [parseUnits("1000")]),
      ).to.be.revertedWith("MarketNotListed()");
    });
    it("WHEN trying to call liquidateAllowed, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(
        auditor.liquidateAllowed(exactlyEnv.notAnFixedLenderAddress, fixedLender.address, owner.address, user.address),
      ).to.be.revertedWith("MarketNotListed()");
      await expect(
        auditor.liquidateAllowed(fixedLender.address, exactlyEnv.notAnFixedLenderAddress, owner.address, user.address),
      ).to.be.revertedWith("MarketNotListed()");
    });
    it("WHEN trying to call seizeAllowed, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(
        auditor.seizeAllowed(exactlyEnv.notAnFixedLenderAddress, fixedLender.address, owner.address, user.address),
      ).to.be.revertedWith("MarketNotListed()");
      await expect(
        auditor.seizeAllowed(fixedLender.address, exactlyEnv.notAnFixedLenderAddress, owner.address, user.address),
      ).to.be.revertedWith("MarketNotListed()");
    });
  });
  describe("FixedLender:", () => {
    describe("GIVEN a NOT not-yet-enabled pool", () => {
      it("WHEN trying to deposit to MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.depositMP("DAI", nextPoolId + INTERVAL * 20, "100")).to.be.revertedWith(
          errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID),
        );
      });
      it("WHEN trying to borrow from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.borrowMP("DAI", nextPoolId + INTERVAL * 20, "2", "2")).to.be.revertedWith(
          errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID),
        );
      });
      it("WHEN trying to withdraw from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.withdrawMP("DAI", nextPoolId + INTERVAL * 20, "100")).to.be.revertedWith(
          errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID, PoolState.MATURED),
        );
      });
      it("WHEN trying to repay to MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.repayMP("DAI", nextPoolId + INTERVAL * 20, "100")).to.be.revertedWith(
          "UnmatchedPoolStateMultiple(" + PoolState.NOT_READY + ", " + PoolState.VALID + ", " + PoolState.MATURED + ")",
        );
      });
    });
    describe("GIVEN a matured pool", () => {
      it("WHEN trying to deposit to MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.depositMP("DAI", nextPoolId - INTERVAL * 20, "100")).to.be.revertedWith(
          errorUnmatchedPool(PoolState.MATURED, PoolState.VALID),
        );
      });
      it("WHEN trying to borrow from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.borrowMP("DAI", nextPoolId - INTERVAL * 20, "3", "3")).to.be.revertedWith(
          errorUnmatchedPool(PoolState.MATURED, PoolState.VALID),
        );
      });
    });
    describe("GIVEN an invalid pool id", () => {
      it("WHEN trying to deposit to MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.depositMP("DAI", nextPoolId + 1, "100")).to.be.revertedWith(
          errorUnmatchedPool(PoolState.INVALID, PoolState.VALID),
        );
      });
      it("WHEN trying to borrow from MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.borrowMP("DAI", nextPoolId + 1, "3", "3")).to.be.revertedWith(
          errorUnmatchedPool(PoolState.INVALID, PoolState.VALID),
        );
      });
      it("WHEN trying to withdraw from MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.withdrawMP("DAI", nextPoolId + 1, "100")).to.be.revertedWith(
          errorUnmatchedPool(PoolState.INVALID, PoolState.VALID, PoolState.MATURED),
        );
      });
      it("WHEN trying to repay to MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.repayMP("DAI", nextPoolId + 1, "100")).to.be.revertedWith(
          "UnmatchedPoolStateMultiple(" + PoolState.INVALID + ", " + PoolState.VALID + ", " + PoolState.MATURED + ")",
        );
      });
    });
  });
  describe("Configurable values: GIVEN an invalid configurable value, THEN it should revert with InvalidParameter error", () => {
    it("WHEN trying to set the spFeeRate with more than 20%", async () => {
      await expect(interestRateModel.setSPFeeRate(parseUnits("0.21"))).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the UFullRate with more than 52", async () => {
      await expect(interestRateModel.setCurveParameters(0, 0, parseUnits("53"), parseUnits("52.1"))).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the UFullRate with UMax same value", async () => {
      await expect(interestRateModel.setCurveParameters(0, 0, parseUnits("5"), parseUnits("5"))).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the UFullRate with more than UMax", async () => {
      await expect(interestRateModel.setCurveParameters(0, 0, parseUnits("3"), parseUnits("3.1"))).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the UMax with more than UFullRate * 3", async () => {
      await expect(interestRateModel.setCurveParameters(0, 0, parseUnits("9.1"), parseUnits("3"))).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the UFullRate with less than 1", async () => {
      await expect(interestRateModel.setCurveParameters(0, 0, parseUnits("2"), parseUnits("0.99"))).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the smartPoolReserveFactor with more than 20%", async () => {
      await expect(fixedLender.setSmartPoolReserveFactor(parseUnits("0.21"))).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the penaltyRate with more than 5% daily", async () => {
      const penaltyRate = parseUnits("0.051").div(86_400);
      await expect(fixedLender.setPenaltyRate(penaltyRate)).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the penaltyRate with less than 1% daily", async () => {
      const penaltyRate = parseUnits("0.0099").div(86_400);
      await expect(fixedLender.setPenaltyRate(penaltyRate)).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the accumulatedEarningsSmoothFactor with more than 4", async () => {
      await expect(fixedLender.setAccumulatedEarningsSmoothFactor(parseUnits("4.01"))).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the maxFuturePools with 0", async () => {
      await expect(fixedLender.setMaxFuturePools(0)).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the dampSpeedUp with more than 100%", async () => {
      await expect(fixedLender.setDampSpeed({ up: parseUnits("1.01"), down: parseUnits("0") })).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the dampSpeedDown with more than 100%", async () => {
      await expect(fixedLender.setDampSpeed({ up: parseUnits("0"), down: parseUnits("1.01") })).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the liquidationIncentive with more than 20%", async () => {
      await expect(auditor.setLiquidationIncentive(parseUnits("1.21"))).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the liquidationIncentive with less than 5%", async () => {
      await expect(auditor.setLiquidationIncentive(parseUnits("1.0499"))).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the collateralFactor with more than 90%", async () => {
      await expect(auditor.setCollateralFactor(fixedLender.address, parseUnits("0.91"))).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the collateralFactor with less than 30%", async () => {
      await expect(auditor.setCollateralFactor(fixedLender.address, parseUnits("0.29"))).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the collateralFactor with an unlisted fixedLender", async () => {
      await expect(auditor.setCollateralFactor(user.address, parseUnits("0.3"))).to.be.revertedWith(
        "MarketNotListed()",
      );
    });
  });
  describe("Configurable values: GIVEN a valid configurable value, THEN it should not revert", () => {
    it("WHEN trying to set the spFeeRate with 20%", async () => {
      await expect(interestRateModel.setSPFeeRate(parseUnits("0.2"))).to.not.be.reverted;
    });
    it("WHEN trying to set the spFeeRate with an intermediate value (10%)", async () => {
      await expect(interestRateModel.setSPFeeRate(parseUnits("0.1"))).to.not.be.reverted;
    });
    it("WHEN trying to set the spFeeRate with 0", async () => {
      await expect(interestRateModel.setSPFeeRate(0)).to.not.be.reverted;
    });
    it("WHEN trying to set the UMax with UFullRate * 3", async () => {
      await expect(interestRateModel.setCurveParameters(0, 0, parseUnits("9"), parseUnits("3"))).to.not.be.reverted;
    });
    it("WHEN trying to set the UFullRate with 1", async () => {
      await expect(interestRateModel.setCurveParameters(0, 0, parseUnits("2"), parseUnits("1"))).to.not.be.reverted;
    });
    it("WHEN trying to set the UFullRate with 52", async () => {
      await expect(interestRateModel.setCurveParameters(0, 0, parseUnits("53"), parseUnits("52"))).to.not.be.reverted;
    });
    it("WHEN trying to set the UFullRate with an intermediate value (4)", async () => {
      await expect(interestRateModel.setCurveParameters(0, 0, parseUnits("10"), parseUnits("4"))).to.not.be.reverted;
    });
    it("WHEN trying to set the smartPoolReserveFactor with 20%", async () => {
      await expect(fixedLender.setSmartPoolReserveFactor(parseUnits("0.2"))).to.not.be.reverted;
    });
    it("WHEN trying to set the smartPoolReserveFactor with an intermediate value (10%)", async () => {
      await expect(fixedLender.setSmartPoolReserveFactor(parseUnits("0.1"))).to.not.be.reverted;
    });
    it("WHEN trying to set the smartPoolReserveFactor with 0", async () => {
      await expect(fixedLender.setSmartPoolReserveFactor(0)).to.not.be.reverted;
    });
    it("WHEN trying to set the penaltyRate with 1% daily", async () => {
      const penaltyRate = parseUnits("0.01").div(86_400);
      await expect(fixedLender.setPenaltyRate(penaltyRate)).to.not.be.reverted;
    });
    it("WHEN trying to set the penaltyRate with 5% daily", async () => {
      const penaltyRate = parseUnits("0.05").div(86_400);
      await expect(fixedLender.setPenaltyRate(penaltyRate)).to.not.be.reverted;
    });
    it("WHEN trying to set the penaltyRate with an intermediate daily value (3%)", async () => {
      const penaltyRate = parseUnits("0.03").div(86_400);
      await expect(fixedLender.setPenaltyRate(penaltyRate)).to.not.be.reverted;
    });
    it("WHEN trying to set the accumulatedEarningsSmoothFactor_ with 0", async () => {
      await expect(fixedLender.setAccumulatedEarningsSmoothFactor(parseUnits("0"))).to.not.be.reverted;
    });
    it("WHEN trying to set the accumulatedEarningsSmoothFactor_ with 4", async () => {
      await expect(fixedLender.setAccumulatedEarningsSmoothFactor(parseUnits("4"))).to.not.be.reverted;
    });
    it("WHEN trying to set the accumulatedEarningsSmoothFactor_ with an intermediate value (2)", async () => {
      await expect(fixedLender.setAccumulatedEarningsSmoothFactor(parseUnits("2"))).to.not.be.reverted;
    });
    it("WHEN trying to set the maxFuturePools with a whole number", async () => {
      await expect(fixedLender.setMaxFuturePools(1)).to.not.be.reverted;
      await expect(fixedLender.setMaxFuturePools(12)).to.not.be.reverted;
      await expect(fixedLender.setMaxFuturePools(24)).to.not.be.reverted;
    });
    it("WHEN trying to set the dampSpeedUp with 0 and dampSpeedDown with 1", async () => {
      await expect(fixedLender.setDampSpeed({ up: parseUnits("0"), down: parseUnits("1") })).to.not.be.reverted;
    });
    it("WHEN trying to set the dampSpeedDown with 0 and dampSpeedUp with 1", async () => {
      await expect(fixedLender.setDampSpeed({ up: parseUnits("1"), down: parseUnits("0") })).to.not.be.reverted;
    });
    it("WHEN trying to set the liquidationIncentive with 5%", async () => {
      await expect(auditor.setLiquidationIncentive(parseUnits("1.05"))).to.not.be.reverted;
    });
    it("WHEN trying to set the liquidationIncentive with 20%", async () => {
      await expect(auditor.setLiquidationIncentive(parseUnits("1.2"))).to.not.be.reverted;
    });
    it("WHEN trying to set the liquidationIncentive with an intermediate value (10%)", async () => {
      await expect(auditor.setLiquidationIncentive(parseUnits("1.1"))).to.not.be.reverted;
    });
    it("WHEN trying to set the collateralFactor with 30%", async () => {
      await expect(auditor.setCollateralFactor(fixedLender.address, parseUnits("0.3"))).to.not.be.reverted;
    });
    it("WHEN trying to set the collateralFactor with 90%", async () => {
      await expect(auditor.setCollateralFactor(fixedLender.address, parseUnits("0.9"))).to.not.be.reverted;
    });
    it("WHEN trying to set the collateralFactor with an intermediate value (60%)", async () => {
      await expect(auditor.setCollateralFactor(fixedLender.address, parseUnits("0.6"))).to.not.be.reverted;
    });
  });
});
