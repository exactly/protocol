import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv } from "./defaultEnv";
import futurePools from "./utils/futurePools";

const nextPoolId = futurePools(1)[0].toNumber();

describe("Market - Pausable", function () {
  let exactlyEnv: DefaultEnv;
  let market: Contract;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  describe("GIVEN a deployed Market contract", () => {
    let PAUSER_ROLE: any;
    beforeEach(async () => {
      [owner, user] = await ethers.getSigners();

      exactlyEnv = await DefaultEnv.create({});
      market = exactlyEnv.getMarket("DAI");
      PAUSER_ROLE = await market.PAUSER_ROLE();

      market.grantRole(PAUSER_ROLE, owner.address);
    });
    it("AND WHEN a pause is called from third parties, THEN it should revert with AccessControl error", async () => {
      await expect(market.connect(user).pause()).to.be.revertedWith("AccessControl");
    });
    it("AND WHEN an unpause is called from third parties, THEN it should revert with AccessControl error", async () => {
      await expect(market.connect(user).unpause()).to.be.revertedWith("AccessControl");
    });
    describe("AND GIVEN a grant in the PAUSER role to another user", () => {
      beforeEach(async () => {
        await market.grantRole(PAUSER_ROLE, user.address);
      });
      it("THEN it should NOT revert when user pauses actions", async () => {
        await expect(market.connect(user).pause()).to.not.be.reverted;
      });
      it("THEN it should NOT revert when user unpauses actions", async () => {
        market.connect(user).pause();
        await expect(market.connect(user).unpause()).to.not.be.reverted;
      });
    });
    describe("AND GIVEN a pause for all actions that have whenNotPaused modifier", () => {
      beforeEach(async () => {
        await exactlyEnv.getUnderlying("DAI").approve(market.address, ethers.constants.MaxUint256);
        await market.pause();
      });
      it("THEN it should revert when trying to deposit to a smart pool", async () => {
        await expect(market.deposit(10n ** 18n, user.address)).to.be.revertedWith("Pausable: paused");
      });
      it("THEN it should revert when trying to deposit to a maturity pool", async () => {
        await expect(market.depositAtMaturity(nextPoolId, "0", "0", user.address)).to.be.revertedWith(
          "Pausable: paused",
        );
      });
      it("THEN it should revert when trying to borrow from a maturity pool", async () => {
        await expect(market.borrowAtMaturity(nextPoolId, "0", "0", user.address, user.address)).to.be.revertedWith(
          "Pausable: paused",
        );
      });
      it("THEN it should revert when trying to repay to a maturity pool", async () => {
        await expect(market.repayAtMaturity(nextPoolId, "0", "0", owner.address)).to.be.revertedWith(
          "Pausable: paused",
        );
      });
      it("THEN it should revert when trying to liquidate a maturity pool position", async () => {
        await expect(market.liquidate(owner.address, "0", market.address)).to.be.revertedWith("Pausable: paused");
      });
      it("THEN it should revert when trying to seize a maturity pool position", async () => {
        await expect(market.seize(owner.address, owner.address, "0")).to.be.revertedWith("Pausable: paused");
      });
      it("THEN it should NOT revert when calling a function that doesn't have whenNotPaused modifier", async () => {
        await expect(market.setMaxFuturePools(24)).to.not.be.reverted;
      });
      it("AND WHEN a pause is called again, THEN it should revert with Pausable error", async () => {
        await expect(market.pause()).to.be.revertedWith("Pausable: paused");
      });
      describe("AND GIVEN an unpause for all actions that have whenNotPaused modifier", () => {
        beforeEach(async () => {
          await market.unpause();
        });
        it("THEN it should NOT revert when trying to call one of them", async () => {
          await expect(exactlyEnv.depositSP("DAI", "100")).to.not.be.reverted;
        });
        it("AND WHEN an unpause is called again, THEN it should revert with Pausable error", async () => {
          await expect(market.unpause()).to.be.revertedWith("Pausable: not paused");
        });
      });
    });
  });
});
