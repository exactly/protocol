import { expect } from "chai";
import { ethers } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { Auditor, InterestRateModel, Market } from "../types";
import futurePools, { INTERVAL } from "./utils/futurePools";
import { DefaultEnv } from "./defaultEnv";

const nextPoolId = futurePools(1)[0].toNumber();

const {
  constants: { MaxUint256 },
  utils: { parseUnits },
} = ethers;

describe("Validations", function () {
  let auditor: Auditor;
  let market: Market;
  let interestRateModel: InterestRateModel;
  let exactlyEnv: DefaultEnv;

  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  before(async () => {
    owner = await ethers.getNamedSigner("deployer");
    [user] = await ethers.getUnnamedSigners();

    exactlyEnv = await DefaultEnv.create({ useRealInterestRateModel: true });
    auditor = exactlyEnv.auditor;
    interestRateModel = exactlyEnv.interestRateModel as InterestRateModel;
    market = exactlyEnv.getMarket("DAI");
  });

  describe("Auditor: GIVEN an unlisted market as parameter", () => {
    it("WHEN trying to enter markets, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(auditor.enterMarket(exactlyEnv.notAnMarketAddress)).to.be.revertedWith("MarketNotListed()");
    });
    it("WHEN trying to exit market, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(auditor.exitMarket(exactlyEnv.notAnMarketAddress)).to.be.revertedWith("MarketNotListed()");
    });
    it("WHEN trying to call checkBorrow, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(auditor.checkBorrow(exactlyEnv.notAnMarketAddress, owner.address)).to.be.revertedWith(
        "MarketNotListed()",
      );
    });
    it("WHEN trying to call checkLiquidation, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(
        auditor.checkLiquidation(exactlyEnv.notAnMarketAddress, market.address, user.address, MaxUint256),
      ).to.be.revertedWith("MarketNotListed()");
      await expect(
        auditor.checkLiquidation(market.address, exactlyEnv.notAnMarketAddress, user.address, MaxUint256),
      ).to.be.revertedWith("MarketNotListed()");
    });
    it("WHEN trying to call checkSeize, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(auditor.checkSeize(market.address, exactlyEnv.notAnMarketAddress)).to.be.revertedWith(
        "MarketNotListed()",
      );
      await expect(auditor.checkSeize(exactlyEnv.notAnMarketAddress, market.address)).to.be.revertedWith(
        "MarketNotListed()",
      );
    });
  });
  describe("Market:", () => {
    describe("GIVEN a NOT not-yet-enabled pool", () => {
      it("WHEN trying to deposit to MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.depositMP("DAI", nextPoolId + INTERVAL * 20, "100")).to.be.revertedWith(
          `UnmatchedPoolState(${PoolState.NOT_READY}, ${PoolState.VALID})`,
        );
      });
      it("WHEN trying to borrow from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.borrowMP("DAI", nextPoolId + INTERVAL * 20, "2", "2")).to.be.revertedWith(
          `UnmatchedPoolState(${PoolState.NOT_READY}, ${PoolState.VALID})`,
        );
      });
      it("WHEN trying to withdraw from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.withdrawMP("DAI", nextPoolId + INTERVAL * 20, "100")).to.be.revertedWith(
          `UnmatchedPoolStates(${PoolState.NOT_READY}, ${PoolState.VALID}, ${PoolState.MATURED})`,
        );
      });
      it("WHEN trying to repay to MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.repayMP("DAI", nextPoolId + INTERVAL * 20, "100")).to.be.revertedWith(
          "UnmatchedPoolStates(" + PoolState.NOT_READY + ", " + PoolState.VALID + ", " + PoolState.MATURED + ")",
        );
      });
    });
    describe("GIVEN a matured pool", () => {
      it("WHEN trying to deposit to MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.depositMP("DAI", nextPoolId - INTERVAL * 20, "100")).to.be.revertedWith(
          `UnmatchedPoolState(${PoolState.MATURED}, ${PoolState.VALID})`,
        );
      });
      it("WHEN trying to borrow from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.borrowMP("DAI", nextPoolId - INTERVAL * 20, "3", "3")).to.be.revertedWith(
          `UnmatchedPoolState(${PoolState.MATURED}, ${PoolState.VALID})`,
        );
      });
    });
    describe("GIVEN an invalid pool id", () => {
      it("WHEN trying to deposit to MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.depositMP("DAI", nextPoolId + 1, "100")).to.be.revertedWith(
          `UnmatchedPoolState(${PoolState.INVALID}, ${PoolState.VALID})`,
        );
      });
      it("WHEN trying to borrow from MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.borrowMP("DAI", nextPoolId + 1, "3", "3")).to.be.revertedWith(
          `UnmatchedPoolState(${PoolState.INVALID}, ${PoolState.VALID})`,
        );
      });
      it("WHEN trying to withdraw from MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.withdrawMP("DAI", nextPoolId + 1, "100")).to.be.revertedWith(
          `UnmatchedPoolStates(${PoolState.INVALID}, ${PoolState.VALID}, ${PoolState.MATURED})`,
        );
      });
      it("WHEN trying to repay to MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.repayMP("DAI", nextPoolId + 1, "100")).to.be.revertedWith(
          "UnmatchedPoolStates(" + PoolState.INVALID + ", " + PoolState.VALID + ", " + PoolState.MATURED + ")",
        );
      });
    });
  });
  describe("Configurable values: GIVEN an invalid configurable value, THEN it should revert with InvalidParameter error", () => {
    it("WHEN trying to set the backupFeeRate with more than 20%", async () => {
      await expect(market.setBackupFeeRate(parseUnits("0.21"))).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the UFullRate with more than 52", async () => {
      await expect(
        interestRateModel.setFixedParameters({ a: 0, b: 0, maxUtilization: parseUnits("53") }, parseUnits("52.1")),
      ).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the UFullRate with UMax same value", async () => {
      await expect(
        interestRateModel.setFixedParameters({ a: 0, b: 0, maxUtilization: parseUnits("5") }, parseUnits("5")),
      ).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the UFullRate with more than UMax", async () => {
      await expect(
        interestRateModel.setFixedParameters({ a: 0, b: 0, maxUtilization: parseUnits("3") }, parseUnits("3.1")),
      ).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the UMax with more than UFullRate * 3", async () => {
      await expect(
        interestRateModel.setFixedParameters({ a: 0, b: 0, maxUtilization: parseUnits("9.1") }, parseUnits("3")),
      ).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the UFullRate with less than 1", async () => {
      await expect(
        interestRateModel.setFixedParameters({ a: 0, b: 0, maxUtilization: parseUnits("2") }, parseUnits("0.99")),
      ).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the reserveFactor with more than 20%", async () => {
      await expect(market.setReserveFactor(parseUnits("0.21"))).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the penaltyRate with more than 5% daily", async () => {
      const penaltyRate = parseUnits("0.051").div(86_400);
      await expect(market.setPenaltyRate(penaltyRate)).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the penaltyRate with less than 1% daily", async () => {
      const penaltyRate = parseUnits("0.0099").div(86_400);
      await expect(market.setPenaltyRate(penaltyRate)).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the earningsAccumulatorSmoothFactor with more than 4", async () => {
      await expect(market.setEarningsAccumulatorSmoothFactor(parseUnits("4.01"))).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the maxFuturePools with 0", async () => {
      await expect(market.setMaxFuturePools(0)).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the maxFuturePools with more than 224", async () => {
      await expect(market.setMaxFuturePools(225)).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the dampSpeedUp with more than 100%", async () => {
      await expect(market.setDampSpeed({ up: parseUnits("1.01"), down: parseUnits("0") })).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the dampSpeedDown with more than 100%", async () => {
      await expect(market.setDampSpeed({ up: parseUnits("0"), down: parseUnits("1.01") })).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the liquidationIncentive with more than 20%", async () => {
      await expect(auditor.setLiquidationIncentive({ liquidator: parseUnits("0.21"), lenders: 0 })).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the liquidationIncentive with less than 5%", async () => {
      await expect(
        auditor.setLiquidationIncentive({ liquidator: parseUnits("0.0499"), lenders: 0 }),
      ).to.be.revertedWith("InvalidParameter()");
    });
    it("WHEN trying to set the adjustFactor with more than 90%", async () => {
      await expect(auditor.setAdjustFactor(market.address, parseUnits("0.91"))).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the adjustFactor with less than 30%", async () => {
      await expect(auditor.setAdjustFactor(market.address, parseUnits("0.29"))).to.be.revertedWith(
        "InvalidParameter()",
      );
    });
    it("WHEN trying to set the adjustFactor with an unlisted market", async () => {
      await expect(auditor.setAdjustFactor(user.address, parseUnits("0.3"))).to.be.revertedWith("MarketNotListed()");
    });
    it("WHEN trying to set the treasuryFeeRate with more than 10%", async () => {
      await expect(market.setTreasury(user.address, parseUnits("0.11"))).to.be.revertedWith("InvalidParameter()");
    });
  });
  describe("Configurable values: GIVEN a valid configurable value, THEN it should not revert", () => {
    it("WHEN trying to set the backupFeeRate with 20%", async () => {
      await expect(market.setBackupFeeRate(parseUnits("0.2"))).to.not.be.reverted;
    });
    it("WHEN trying to set the backupFeeRate with an intermediate value (10%)", async () => {
      await expect(market.setBackupFeeRate(parseUnits("0.1"))).to.not.be.reverted;
    });
    it("WHEN trying to set the backupFeeRate with 0", async () => {
      await expect(market.setBackupFeeRate(0)).to.not.be.reverted;
    });
    it("WHEN trying to set the UMax with UFullRate * 3", async () => {
      await expect(
        interestRateModel.setFixedParameters({ a: 0, b: 0, maxUtilization: parseUnits("9") }, parseUnits("3")),
      ).to.not.be.reverted;
    });
    it("WHEN trying to set the UFullRate with 1", async () => {
      await expect(
        interestRateModel.setFixedParameters({ a: 0, b: 0, maxUtilization: parseUnits("2") }, parseUnits("1")),
      ).to.not.be.reverted;
    });
    it("WHEN trying to set the UFullRate with 52", async () => {
      await expect(
        interestRateModel.setFixedParameters({ a: 0, b: 0, maxUtilization: parseUnits("53") }, parseUnits("52")),
      ).to.not.be.reverted;
    });
    it("WHEN trying to set the UFullRate with an intermediate value (4)", async () => {
      await expect(
        interestRateModel.setFixedParameters({ a: 0, b: 0, maxUtilization: parseUnits("10") }, parseUnits("4")),
      ).to.not.be.reverted;
    });
    it("WHEN trying to set the reserveFactor with 20%", async () => {
      await expect(market.setReserveFactor(parseUnits("0.2"))).to.not.be.reverted;
    });
    it("WHEN trying to set the reserveFactor with an intermediate value (10%)", async () => {
      await expect(market.setReserveFactor(parseUnits("0.1"))).to.not.be.reverted;
    });
    it("WHEN trying to set the reserveFactor with 0", async () => {
      await expect(market.setReserveFactor(0)).to.not.be.reverted;
    });
    it("WHEN trying to set the penaltyRate with 1% daily", async () => {
      const penaltyRate = parseUnits("0.01").div(86_400);
      await expect(market.setPenaltyRate(penaltyRate)).to.not.be.reverted;
    });
    it("WHEN trying to set the penaltyRate with 5% daily", async () => {
      const penaltyRate = parseUnits("0.05").div(86_400);
      await expect(market.setPenaltyRate(penaltyRate)).to.not.be.reverted;
    });
    it("WHEN trying to set the penaltyRate with an intermediate daily value (3%)", async () => {
      const penaltyRate = parseUnits("0.03").div(86_400);
      await expect(market.setPenaltyRate(penaltyRate)).to.not.be.reverted;
    });
    it("WHEN trying to set the earningsAccumulatorSmoothFactor_ with 0", async () => {
      await expect(market.setEarningsAccumulatorSmoothFactor(parseUnits("0"))).to.not.be.reverted;
    });
    it("WHEN trying to set the earningsAccumulatorSmoothFactor_ with 4", async () => {
      await expect(market.setEarningsAccumulatorSmoothFactor(parseUnits("4"))).to.not.be.reverted;
    });
    it("WHEN trying to set the earningsAccumulatorSmoothFactor_ with an intermediate value (2)", async () => {
      await expect(market.setEarningsAccumulatorSmoothFactor(parseUnits("2"))).to.not.be.reverted;
    });
    it("WHEN trying to set the maxFuturePools with a whole number", async () => {
      await expect(market.setMaxFuturePools(1)).to.not.be.reverted;
      await expect(market.setMaxFuturePools(12)).to.not.be.reverted;
      await expect(market.setMaxFuturePools(24)).to.not.be.reverted;
      await expect(market.setMaxFuturePools(224)).to.not.be.reverted;
    });
    it("WHEN trying to set the dampSpeedUp with 0 and dampSpeedDown with 1", async () => {
      await expect(market.setDampSpeed({ up: parseUnits("0"), down: parseUnits("1") })).to.not.be.reverted;
    });
    it("WHEN trying to set the dampSpeedDown with 0 and dampSpeedUp with 1", async () => {
      await expect(market.setDampSpeed({ up: parseUnits("1"), down: parseUnits("0") })).to.not.be.reverted;
    });
    it("WHEN trying to set the liquidationIncentive with 5%", async () => {
      await expect(auditor.setLiquidationIncentive({ liquidator: parseUnits("0.05"), lenders: 0 })).to.not.be.reverted;
    });
    it("WHEN trying to set the liquidationIncentive with 20%", async () => {
      await expect(auditor.setLiquidationIncentive({ liquidator: parseUnits("0.2"), lenders: 0 })).to.not.be.reverted;
    });
    it("WHEN trying to set the liquidationIncentive with an intermediate value (10%)", async () => {
      await expect(auditor.setLiquidationIncentive({ liquidator: parseUnits("0.1"), lenders: 0 })).to.not.be.reverted;
    });
    it("WHEN trying to set the adjustFactor with 30%", async () => {
      await expect(auditor.setAdjustFactor(market.address, parseUnits("0.3"))).to.not.be.reverted;
    });
    it("WHEN trying to set the adjustFactor with 90%", async () => {
      await expect(auditor.setAdjustFactor(market.address, parseUnits("0.9"))).to.not.be.reverted;
    });
    it("WHEN trying to set the adjustFactor with an intermediate value (60%)", async () => {
      await expect(auditor.setAdjustFactor(market.address, parseUnits("0.6"))).to.not.be.reverted;
    });
    it("WHEN trying to set the treasuryFeeRate with 10%", async () => {
      await expect(market.setTreasury(user.address, parseUnits("0.1"))).to.not.be.reverted;
    });
    it("WHEN trying to set the treasuryFeeRate with 0", async () => {
      await expect(market.setTreasury(user.address, 0)).to.not.be.reverted;
    });
  });
});

enum PoolState {
  NONE,
  INVALID,
  MATURED,
  VALID,
  NOT_READY,
}
