import { expect } from "chai";
import { ethers } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { Market } from "../../types";
import { DefaultEnv } from "./defaultEnv";
import futurePools from "./utils/futurePools";
import { keccak256, toUtf8Bytes } from "ethers";

describe("Market - Pausable", function () {
  let exactlyEnv: DefaultEnv;
  let market: Market;
  let owner: SignerWithAddress;
  let account: SignerWithAddress;
  let nextPoolId: number;

  describe("GIVEN a deployed Market contract", () => {
    let PAUSER_ROLE: string;

    beforeEach(async () => {
      owner = await ethers.getNamedSigner("deployer");
      [account] = await ethers.getUnnamedSigners();

      exactlyEnv = await DefaultEnv.create();
      market = exactlyEnv.getMarket("DAI");
      PAUSER_ROLE = keccak256(toUtf8Bytes("PAUSER_ROLE"));

      await market.grantRole(PAUSER_ROLE, owner.address);
      nextPoolId = (await futurePools(1))[0];
    });

    it("AND WHEN a pause is called from third parties, THEN it should revert with AccessControl error", async () => {
      await expect(market.connect(account).pause()).to.be.revertedWithCustomError(market, "NotPausingRole");
    });

    it("AND WHEN an unpause is called from third parties, THEN it should revert with AccessControl error", async () => {
      await expect(market.connect(account).unpause()).to.be.revertedWithoutReason();
    });

    describe("AND GIVEN a grant in the PAUSER role to another account", () => {
      beforeEach(async () => {
        await market.grantRole(PAUSER_ROLE, account.address);
      });

      it("THEN it should NOT revert when account pauses actions", async () => {
        await expect(market.connect(account).pause()).to.not.be.reverted;
      });

      it("THEN it should NOT revert when account unpauses actions", async () => {
        await market.connect(account).pause();
        await expect(market.connect(account).unpause()).to.not.be.reverted;
      });
    });

    describe("AND GIVEN a pause for all actions that have whenNotPaused modifier", () => {
      beforeEach(async () => {
        await exactlyEnv.getUnderlying("DAI").approve(market.target, ethers.MaxUint256);
        await market.pause();
      });

      it("THEN it should revert when trying to deposit to a smart pool", async () => {
        await expect(market.deposit(10n ** 18n, account.address)).to.be.revertedWithoutReason();
      });

      it("THEN it should revert when trying to deposit to a maturity pool", async () => {
        await expect(market.depositAtMaturity(nextPoolId, "0", "0", account.address)).to.be.revertedWithoutReason();
      });

      it("THEN it should revert when trying to borrow from a maturity pool", async () => {
        await expect(
          market.borrowAtMaturity(nextPoolId, "0", "0", account.address, account.address),
        ).to.be.revertedWithoutReason();
      });

      it("THEN it should revert when trying to repay to a maturity pool", async () => {
        await expect(market.repayAtMaturity(nextPoolId, "0", "0", owner.address)).to.be.revertedWithoutReason();
      });

      it("THEN it should revert when trying to liquidate a maturity pool position", async () => {
        await expect(market.liquidate(owner.address, "0", market.target)).to.be.revertedWithoutReason();
      });

      it("THEN it should revert when trying to seize a maturity pool position", async () => {
        await expect(market.seize(owner.address, owner.address, "0")).to.be.revertedWithoutReason();
      });

      it("THEN it should NOT revert when calling a function that doesn't have whenNotPaused modifier", async () => {
        await expect(market.setMaxFuturePools(24)).to.not.be.reverted;
      });

      it("AND WHEN a pause is called again, THEN it should revert with Pausable error", async () => {
        await expect(market.pause()).to.be.revertedWithoutReason();
      });

      describe("AND GIVEN an unpause for all actions that have whenNotPaused modifier", () => {
        beforeEach(async () => {
          await market.unpause();
        });

        it("THEN it should NOT revert when trying to call one of them", async () => {
          await expect(exactlyEnv.depositSP("DAI", "100")).to.not.be.reverted;
        });

        it("AND WHEN an unpause is called again, THEN it should revert with Pausable error", async () => {
          await expect(market.unpause()).to.be.revertedWithoutReason();
        });
      });
    });
  });
});
