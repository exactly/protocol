import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { Market, Leverager, ERC20 } from "../types";

describe("Leverager", function () {
  let usdc: ERC20;
  let marketUSDC: Market;
  let leverager: Leverager;
  let alice: SignerWithAddress;

  before(async () => {
    [alice] = await ethers.getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture("Leverager");
    usdc = await ethers.getContract<ERC20>("USDC");
    marketUSDC = await ethers.getContract<Market>("MarketUSDC");
    leverager = await ethers.getContract<Leverager>("Leverager", alice);
  });

  describe("GIVEN an approval of the MarketUSDC to spend USDC from the leverage contract", () => {
    it("THEN the tx should emit Approval", async () => {
      await expect(leverager.approve(marketUSDC.address))
        .to.emit(usdc, "Approval")
        .withArgs(leverager.address, marketUSDC.address, ethers.constants.MaxUint256);
    });
  });
  describe("AND GIVEN an approval of an invalid address to spend USDC from the leverage contract", () => {
    it("THEN the tx should revert", async () => {
      await expect(leverager.approve(leverager.address)).to.be.revertedWithCustomError(leverager, "MarketNotListed");
    });
  });
});
