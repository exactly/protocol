import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { Result } from "ethers";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { Market, MockERC20, RewardsController } from "../../types";
import timelockExecute from "./utils/timelockExecute";

const { parseUnits, getUnnamedSigners, getNamedSigner, getContract } = ethers;

describe("RewardsController", function () {
  let op: MockERC20;
  let usdc: MockERC20;
  let marketUSDC: Market;
  let rewardsController: RewardsController;

  let alice: SignerWithAddress;
  let multisig: SignerWithAddress;

  before(async () => {
    [alice] = await getUnnamedSigners();
    multisig = await getNamedSigner("multisig");
  });

  beforeEach(async () => {
    await deployments.fixture("Markets");

    op = await getContract<MockERC20>("OP", alice);
    usdc = await getContract<MockERC20>("USDC.e", alice);
    marketUSDC = await getContract<Market>("MarketUSDC.e", alice);
    rewardsController = await getContract<RewardsController>("RewardsController", alice);

    await op.mint(rewardsController.target, parseUnits("600000"));
    await usdc.mint(alice.address, parseUnits("100", 6));
    await usdc.approve(marketUSDC.target, parseUnits("100", 6));
  });

  describe("WHEN operating with the USDC Market", () => {
    beforeEach(async () => {
      await marketUSDC.deposit(parseUnits("100", 6), alice.address);
      await marketUSDC.borrow(parseUnits("20", 6), alice.address, alice.address);
      await marketUSDC.borrow(parseUnits("20", 6), alice.address, alice.address);
    });

    it("THEN the claimable amount is positive", async () => {
      const claimableBalance = await rewardsController.allClaimable(alice.address, op.target);
      await rewardsController["claim((address,bool[])[],address,address[])"](
        [{ market: marketUSDC.target, operations: [false, true] }],
        alice.address,
        [op.target],
      );
      const claimedBalance = await op.balanceOf(alice.address);

      expect(claimableBalance).to.be.greaterThan(0);
      expect(claimedBalance).to.be.greaterThan(0);
    });

    it("THEN allRewards return op address", async () => {
      const rewards = await rewardsController.allRewards();

      expect(rewards[0]).to.be.eq(op.target);
    });

    it("AND trying to claim with invalid market THEN the claimable amount is 0", async () => {
      const marketOps = [{ market: alice.address, operations: [false, true] }];
      const claimableBalance = await rewardsController.claimable(marketOps, alice.address, op.target);
      await rewardsController["claim((address,bool[])[],address,address[])"](marketOps, alice.address, [op.target]);
      const claimedBalance = await op.balanceOf(alice.address);

      expect(claimableBalance).to.be.eq(0);
      expect(claimedBalance).to.be.eq(0);
    });

    it("AND calling allClaimable with invalid reward asset THEN the claimable amount is 0", async () => {
      await expect(
        rewardsController.allClaimable(alice.address, alice.address, { gasLimit: 1_000_000 }),
      ).to.be.revertedWithoutReason();
    });

    it("AND setting a keeper enables claiming on behalf of an account", async () => {
      await timelockExecute(multisig, rewardsController, "setKeeper", [alice.address, alice.address]);

      const marketOps = [{ market: marketUSDC.target, operations: [false, true] }];
      await rewardsController.connect(alice).claimOnBehalfOf(marketOps, alice.address, [op.target]);
    });
  });

  describe("GIVEN a zero utilization level", () => {
    beforeEach(async () => {
      await usdc.mint(alice.address, parseUnits("1000"));
      await usdc.approve(marketUSDC.target, parseUnits("1001"));

      await marketUSDC.deposit(parseUnits("1000"), alice.address);
      await marketUSDC.borrow(1, alice.address, alice.address);
    });

    it("THEN a following operation should not revert", async () => {
      await expect(marketUSDC.deposit(parseUnits("100", 6), alice.address)).to.not.be.reverted;
    });
  });

  describe("WHEN withdrawing OP rewards from the RewardsController contract", () => {
    let balanceBefore: bigint;

    beforeEach(async () => {
      balanceBefore = await op.balanceOf(rewardsController.target);
      await timelockExecute(multisig, rewardsController, "withdraw", [op.target, multisig.address]);
    });

    it("THEN RewardsController is emptied", async () => {
      expect(balanceBefore).to.be.greaterThan(0);
      expect(await op.balanceOf(rewardsController.target)).to.eq(0);
    });
  });

  describe("GIVEN a regular account", () => {
    it("WHEN trying to call config, THEN the transaction should revert", async () => {
      const rewardsConfig = (await rewardsController.rewardConfig(marketUSDC.target, op.target)) as unknown as Result;
      await expect(
        rewardsController.config([rewardsConfig.toObject() as RewardsController.ConfigStruct]),
      ).to.be.revertedWithoutReason();
    });

    it("WHEN trying to call withdraw, THEN the transaction should revert", async () => {
      await expect(rewardsController.withdraw(op.target, alice.address)).to.be.revertedWithoutReason();
    });

    it("WHEN trying to call initialize, THEN the transaction should revert", async () => {
      await expect(rewardsController.initialize()).to.be.revertedWithoutReason();
    });
  });
});
