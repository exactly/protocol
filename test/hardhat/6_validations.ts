import { expect } from "chai";
import { ethers } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { Auditor, Market, Previewer__factory } from "../../types";
import futurePools, { INTERVAL } from "./utils/futurePools";
import { DefaultEnv } from "./defaultEnv";

const { ZeroAddress, MaxUint256, parseUnits, getContractFactory } = ethers;

describe("Validations", function () {
  let auditor: Auditor;
  let market: Market;
  let exactlyEnv: DefaultEnv;

  let owner: SignerWithAddress;
  let account: SignerWithAddress;
  let nextPoolId: number;

  before(async () => {
    owner = await ethers.getNamedSigner("deployer");
    [account] = await ethers.getUnnamedSigners();

    exactlyEnv = await DefaultEnv.create({ useRealInterestRateModel: true });
    auditor = exactlyEnv.auditor;
    market = exactlyEnv.getMarket("DAI");
    nextPoolId = (await futurePools(1))[0];
  });

  describe("Auditor: GIVEN an unlisted market as parameter", () => {
    it("WHEN trying to enter markets, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(auditor.enterMarket(exactlyEnv.notAnMarketAddress)).to.be.revertedWithCustomError(
        auditor,
        "MarketNotListed",
      );
    });

    it("WHEN trying to exit market, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(auditor.exitMarket(exactlyEnv.notAnMarketAddress)).to.be.revertedWithCustomError(
        auditor,
        "MarketNotListed",
      );
    });

    it("WHEN trying to call checkBorrow, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(auditor.checkBorrow(exactlyEnv.notAnMarketAddress, owner.address)).to.be.revertedWithCustomError(
        auditor,
        "MarketNotListed",
      );
    });

    it("WHEN trying to call checkLiquidation, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(
        auditor.checkLiquidation(exactlyEnv.notAnMarketAddress, market.target, account.address, MaxUint256),
      ).to.be.revertedWithCustomError(auditor, "MarketNotListed");
      await expect(
        auditor.checkLiquidation(market.target, exactlyEnv.notAnMarketAddress, account.address, MaxUint256),
      ).to.be.revertedWithCustomError(auditor, "MarketNotListed");
    });

    it("WHEN trying to call checkSeize, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(auditor.checkSeize(market.target, exactlyEnv.notAnMarketAddress)).to.be.revertedWithCustomError(
        auditor,
        "MarketNotListed",
      );
      await expect(auditor.checkSeize(exactlyEnv.notAnMarketAddress, market.target)).to.be.revertedWithCustomError(
        auditor,
        "MarketNotListed",
      );
    });

    it("WHEN trying to set the adjustFactor with an unlisted market", async () => {
      await expect(auditor.setAdjustFactor(account.address, parseUnits("0.3"))).to.be.revertedWithCustomError(
        auditor,
        "MarketNotListed",
      );
    });
  });

  describe("Market:", () => {
    describe("GIVEN a NOT not-yet-enabled pool", () => {
      it("WHEN trying to deposit to MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.depositMP("DAI", nextPoolId + INTERVAL * 20, "100"))
          .to.be.revertedWithCustomError(market, "UnmatchedPoolState")
          .withArgs(PoolState.NOT_READY, PoolState.VALID);
      });

      it("WHEN trying to borrow from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.borrowMP("DAI", nextPoolId + INTERVAL * 20, "2", "2"))
          .to.be.revertedWithCustomError(market, "UnmatchedPoolState")
          .withArgs(PoolState.NOT_READY, PoolState.VALID);
      });

      it("WHEN trying to withdraw from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.withdrawMP("DAI", nextPoolId + INTERVAL * 20, "100"))
          .to.be.revertedWithCustomError(market, "UnmatchedPoolStates")
          .withArgs(PoolState.NOT_READY, PoolState.VALID, PoolState.MATURED);
      });

      it("WHEN trying to repay to MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.repayMP("DAI", nextPoolId + INTERVAL * 20, "100"))
          .to.be.revertedWithCustomError(market, "UnmatchedPoolStates")
          .withArgs(PoolState.NOT_READY, PoolState.VALID, PoolState.MATURED);
      });
    });

    describe("GIVEN a matured pool", () => {
      it("WHEN trying to deposit to MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.depositMP("DAI", nextPoolId - INTERVAL * 20, "100"))
          .to.be.revertedWithCustomError(market, "UnmatchedPoolState")
          .withArgs(PoolState.MATURED, PoolState.VALID);
      });

      it("WHEN trying to borrow from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.borrowMP("DAI", nextPoolId - INTERVAL * 20, "3", "3"))
          .to.be.revertedWithCustomError(market, "UnmatchedPoolState")
          .withArgs(PoolState.MATURED, PoolState.VALID);
      });
    });

    describe("GIVEN an invalid pool id", () => {
      it("WHEN trying to deposit to MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.depositMP("DAI", nextPoolId + 1, "100"))
          .to.be.revertedWithCustomError(market, "UnmatchedPoolState")
          .withArgs(PoolState.INVALID, PoolState.VALID);
      });

      it("WHEN trying to borrow from MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.borrowMP("DAI", nextPoolId + 1, "3", "3"))
          .to.be.revertedWithCustomError(market, "UnmatchedPoolState")
          .withArgs(PoolState.INVALID, PoolState.VALID);
      });

      it("WHEN trying to withdraw from MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.withdrawMP("DAI", nextPoolId + 1, "100"))
          .to.be.revertedWithCustomError(market, "UnmatchedPoolStates")
          .withArgs(PoolState.INVALID, PoolState.VALID, PoolState.MATURED);
      });

      it("WHEN trying to repay to MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(exactlyEnv.repayMP("DAI", nextPoolId + 1, "100"))
          .to.be.revertedWithCustomError(market, "UnmatchedPoolStates")
          .withArgs(PoolState.INVALID, PoolState.VALID, PoolState.MATURED);
      });
    });
  });

  it("Previewer is deployed", async () => {
    const factory = (await getContractFactory("Previewer")) as Previewer__factory;
    await factory.deploy(auditor.target, ZeroAddress, ZeroAddress);
  });
});

enum PoolState {
  NONE,
  INVALID,
  MATURED,
  VALID,
  NOT_READY,
}
