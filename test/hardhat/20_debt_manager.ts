import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { Market, DebtManager, ERC20 } from "../../types";

describe("DebtManager", function () {
  let usdc: ERC20;
  let marketUSDC: Market;
  let debtManager: DebtManager;
  let alice: SignerWithAddress;

  before(async () => {
    [alice] = await ethers.getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture("DebtManager");
    usdc = await ethers.getContract<ERC20>("USDC");
    marketUSDC = await ethers.getContract<Market>("MarketUSDC");
    debtManager = await ethers.getContract<DebtManager>("DebtManager", alice);
  });

  describe("GIVEN an approval of the MarketUSDC to spend USDC from the leverage contract", () => {
    it("THEN the tx should emit Approval", async () => {
      await expect(debtManager.approve(marketUSDC.target))
        .to.emit(usdc, "Approval")
        .withArgs(debtManager.target, marketUSDC.target, ethers.MaxUint256);
    });
  });

  describe("AND GIVEN an approval of an invalid address to spend USDC from the leverage contract", () => {
    it("THEN the tx should revert", async () => {
      await expect(debtManager.approve(debtManager.target)).to.be.revertedWithCustomError(
        debtManager,
        "MarketNotListed",
      );
    });
  });
});
