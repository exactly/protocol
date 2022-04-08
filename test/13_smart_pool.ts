import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ExaTime } from "./exactlyUtils";
import { DefaultEnv } from "./defaultEnv";

describe("Smart Pool", function () {
  let exactlyEnv: DefaultEnv;

  let underlyingTokenDAI: Contract;
  let fixedLenderDAI: Contract;
  let underlyingTokenWBTC: Contract;
  let fixedLenderWBTC: Contract;
  let bob: SignerWithAddress;
  let john: SignerWithAddress;
  const bobBalancePre = parseUnits("2000");
  const johnBalancePre = parseUnits("2000");
  const exaTime: ExaTime = new ExaTime();
  const nextPoolId: number = exaTime.nextPoolID() + 86_400 * 14; // we add 14 days so we make sure we are far from the previous timestamp blocks

  beforeEach(async () => {
    [, bob, john] = await ethers.getSigners();

    exactlyEnv = await DefaultEnv.create({});
    underlyingTokenDAI = exactlyEnv.getUnderlying("DAI");
    fixedLenderDAI = exactlyEnv.getFixedLender("DAI");

    underlyingTokenWBTC = exactlyEnv.getUnderlying("WBTC");
    fixedLenderWBTC = exactlyEnv.getFixedLender("WBTC");

    // From Owner to User
    await underlyingTokenDAI.transfer(bob.address, bobBalancePre);
    await underlyingTokenWBTC.transfer(bob.address, parseUnits("1", 8));
    await underlyingTokenDAI.transfer(john.address, johnBalancePre);
  });

  describe("GIVEN bob and john have 2000DAI in balance, AND deposit 1000DAI each", () => {
    beforeEach(async () => {
      await underlyingTokenDAI.connect(bob).approve(fixedLenderDAI.address, bobBalancePre);
      await underlyingTokenDAI.connect(john).approve(fixedLenderDAI.address, johnBalancePre);

      await fixedLenderDAI.connect(bob).deposit(parseUnits("1000"), bob.address);
      await fixedLenderDAI.connect(john).deposit(parseUnits("1000"), john.address);
    });
    it("THEN balance of DAI in contract is 2000", async () => {
      let balanceOfAssetInContract = await underlyingTokenDAI.balanceOf(fixedLenderDAI.address);

      expect(balanceOfAssetInContract).to.equal(parseUnits("2000"));
    });
    it("THEN balance of eDAI in BOB's address is 1000", async () => {
      let balanceOfETokenInUserAddress = await fixedLenderDAI.balanceOf(bob.address);

      expect(balanceOfETokenInUserAddress).to.equal(parseUnits("1000"));
    });
    it("AND WHEN bob deposits 100DAI more, THEN event Deposit is emitted", async () => {
      await expect(fixedLenderDAI.connect(bob).deposit(parseUnits("100"), bob.address)).to.emit(
        fixedLenderDAI,
        "Deposit",
      );
    });
    describe("AND bob withdraws 500DAI", () => {
      beforeEach(async () => {
        let amountToWithdraw = parseUnits("500");
        await fixedLenderDAI.connect(bob).withdraw(amountToWithdraw, bob.address, bob.address);
      });
      it("THEN balance of DAI in contract is 1500", async () => {
        let balanceOfAssetInContract = await underlyingTokenDAI.balanceOf(fixedLenderDAI.address);

        expect(balanceOfAssetInContract).to.equal(parseUnits("1500"));
      });
      it("THEN balance of eDAI in BOB's address is 500", async () => {
        let balanceOfETokenInUserAddress = await fixedLenderDAI.balanceOf(bob.address);

        expect(balanceOfETokenInUserAddress).to.equal(parseUnits("500"));
      });
      it("AND WHEN bob withdraws 100DAI more, THEN event Withdraw is emitted", async () => {
        await expect(fixedLenderDAI.connect(bob).withdraw(parseUnits("100"), bob.address, bob.address)).to.emit(
          fixedLenderDAI,
          "Withdraw",
        );
      });
      it("AND WHEN bob wants to withdraw 600DAI more, THEN it reverts because his eDAI balance is not enough", async () => {
        await expect(
          fixedLenderDAI.connect(bob).withdraw(parseUnits("600"), bob.address, bob.address),
        ).to.be.revertedWith("0x11");
      });
      it("AND WHEN bob wants to withdraw all the assets, THEN he uses redeem", async () => {
        await expect(
          fixedLenderDAI.connect(bob).redeem(await fixedLenderDAI.balanceOf(bob.address), bob.address, bob.address),
        ).to.not.be.reverted;
        const bobBalancePost = await underlyingTokenDAI.balanceOf(bob.address);
        expect(bobBalancePre).to.equal(bobBalancePost);
      });
    });
  });

  describe("GIVEN bob has 1WBTC in balance, AND deposit 1WBTC", () => {
    beforeEach(async () => {
      let bobBalance = parseUnits("1", 8);
      await underlyingTokenWBTC.connect(bob).approve(fixedLenderWBTC.address, bobBalance);

      await fixedLenderWBTC.connect(bob).deposit(parseUnits("1", 8), bob.address);
    });
    it("THEN balance of WBTC in contract is 1", async () => {
      let balanceOfAssetInContract = await underlyingTokenWBTC.balanceOf(fixedLenderWBTC.address);

      expect(balanceOfAssetInContract).to.equal(parseUnits("1", 8));
    });
    it("THEN balance of eWBTC in BOB's address is 1", async () => {
      let balanceOfETokenInUserAddress = await fixedLenderWBTC.balanceOf(bob.address);

      expect(balanceOfETokenInUserAddress).to.equal(parseUnits("1", 8));
    });
  });

  describe("GIVEN bob deposits 100 DAI (collateralization rate 80%)", () => {
    beforeEach(async () => {
      exactlyEnv.switchWallet(bob);
      await exactlyEnv.depositSP("DAI", "100");
      // we add liquidity to the maturity
      console.log("ACA");
      await exactlyEnv.depositMP("DAI", nextPoolId, "60");
    });
    it("WHEN trying to transfer to another user the entire position (100 eDAI) THEN it should not revert", async () => {
      await expect(fixedLenderDAI.connect(bob).transfer(john.address, parseUnits("100"))).to.not.be.reverted;
    });
    // maturity        1649894400
    // block.timestamp 1649378052
    // maturity        1649894400
    // block.timestamp 1650499513
    describe("AND GIVEN bob borrows 60 DAI from a maturity", () => {
      beforeEach(async () => {
        await exactlyEnv.borrowMP("DAI", nextPoolId, "60");
      });
      it("WHEN trying to transfer to another user the entire position (100 eDAI) without repaying first THEN it reverts with INSUFFICIENT_LIQUIDITY", async () => {
        await expect(fixedLenderDAI.connect(bob).transfer(john.address, parseUnits("100"))).to.be.revertedWith(
          "InsufficientLiquidity()",
        );
      });
      it("WHEN trying to call transferFrom to transfer to another user the entire position (100 eDAI) without repaying first THEN it reverts with INSUFFICIENT_LIQUIDITY", async () => {
        await expect(
          fixedLenderDAI.connect(bob).transferFrom(bob.address, john.address, parseUnits("100")),
        ).to.be.revertedWith("InsufficientLiquidity()");
      });
      it("AND WHEN trying to transfer a small amount that doesnt cause a shortfall (10 eDAI, should move collateralization from 60% to 66%) without repaying first THEN it is allowed", async () => {
        await expect(fixedLenderDAI.connect(bob).transfer(john.address, parseUnits("10"))).to.not.be.reverted;
      });
      it("AND WHEN trying to call transferFrom to transfer a small amount that doesnt cause a shortfall (10 eDAI, should move collateralization from 60% to 66%) without repaying first THEN it is allowed", async () => {
        fixedLenderDAI.connect(bob).approve(john.address, parseUnits("10"));
        await expect(fixedLenderDAI.connect(john).transferFrom(bob.address, john.address, parseUnits("10"))).to.not.be
          .reverted;
      });
      it("WHEN trying to withdraw the entire position (100 DAI) without repaying first THEN it reverts with INSUFFICIENT_LIQUIDITY", async () => {
        await expect(exactlyEnv.withdrawSP("DAI", "100")).to.be.revertedWith("InsufficientLiquidity()");
      });
      it("AND WHEN trying to withdraw a small amount that doesnt cause a shortfall (10 DAI, should move collateralization from 60% to 66%) without repaying first THEN it is allowed", async () => {
        await expect(exactlyEnv.withdrawSP("DAI", "10")).to.not.be.reverted;
      });
    });
  });
});
