import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ExaTime } from "./exactlyUtils";
import { DefaultEnv } from "./defaultEnv";

describe("FixedLender - Pausable", function () {
  let exactlyEnv: DefaultEnv;
  let fixedLender: Contract;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  const exaTime: ExaTime = new ExaTime();
  const nextPoolId: number = exaTime.nextPoolID();

  describe("GIVEN a deployed FixedLender contract", () => {
    let PAUSER_ROLE: any;
    beforeEach(async () => {
      [owner, user] = await ethers.getSigners();

      exactlyEnv = await DefaultEnv.create({});
      fixedLender = exactlyEnv.getFixedLender("DAI");
      PAUSER_ROLE = await fixedLender.PAUSER_ROLE();

      fixedLender.grantRole(PAUSER_ROLE, owner.address);
    });
    it("AND WHEN a pause is called from third parties, THEN it should revert with AccessControl error", async () => {
      await expect(fixedLender.connect(user).pause()).to.be.revertedWith("AccessControl");
    });
    it("AND WHEN an unpause is called from third parties, THEN it should revert with AccessControl error", async () => {
      await expect(fixedLender.connect(user).unpause()).to.be.revertedWith("AccessControl");
    });
    describe("AND GIVEN a grant in the PAUSER role to another user", () => {
      beforeEach(async () => {
        await fixedLender.grantRole(PAUSER_ROLE, user.address);
      });
      it("THEN it should NOT revert when user pauses actions", async () => {
        await expect(fixedLender.connect(user).pause()).to.not.be.reverted;
      });
      it("THEN it should NOT revert when user unpauses actions", async () => {
        fixedLender.connect(user).pause();
        await expect(fixedLender.connect(user).unpause()).to.not.be.reverted;
      });
    });
    describe("AND GIVEN a pause for all actions that have whenNotPaused modifier", () => {
      beforeEach(async () => {
        await fixedLender.pause();
      });
      it("THEN it should revert when trying to deposit to a smart pool", async () => {
        await expect(fixedLender.depositToSmartPool("0")).to.be.revertedWith("Pausable: paused");
      });
      it("THEN it should revert when trying to deposit to a maturity pool", async () => {
        await expect(fixedLender.depositToMaturityPool("0", nextPoolId, "0")).to.be.revertedWith("Pausable: paused");
      });
      it("THEN it should revert when trying to borrow from a maturity pool", async () => {
        await expect(fixedLender.borrowFromMaturityPool("0", nextPoolId, "0")).to.be.revertedWith("Pausable: paused");
      });
      it("THEN it should revert when trying to repay to a maturity pool", async () => {
        await expect(fixedLender.repayToMaturityPool(owner.address, nextPoolId, "0", "0")).to.be.revertedWith(
          "Pausable: paused",
        );
      });
      it("THEN it should revert when trying to liquidate a maturity pool position", async () => {
        await expect(
          fixedLender.liquidate(owner.address, "0", "0", fixedLender.address, nextPoolId),
        ).to.be.revertedWith("Pausable: paused");
      });
      it("THEN it should revert when trying to seize a maturity pool position", async () => {
        await expect(fixedLender.seize(owner.address, owner.address, "0")).to.be.revertedWith("Pausable: paused");
      });
      it("AND WHEN a pause is called again, THEN it should revert with Pausable error", async () => {
        await expect(fixedLender.pause()).to.be.revertedWith("Pausable: paused");
      });
      describe("AND GIVEN an unpause for all actions that have whenNotPaused modifier", () => {
        beforeEach(async () => {
          await fixedLender.unpause();
        });
        it("THEN it should NOT revert when trying to call one of them", async () => {
          await expect(exactlyEnv.depositSP("DAI", "100")).to.not.be.reverted;
        });
        it("AND WHEN an unpause is called again, THEN it should revert with Pausable error", async () => {
          await expect(fixedLender.unpause()).to.be.revertedWith("Pausable: not paused");
        });
      });
    });
  });
});
