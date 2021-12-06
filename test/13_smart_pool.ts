import { expect } from "chai";
import { ethers } from "hardhat";
import { BigNumber, Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv, ExactlyEnv } from "./exactlyUtils";

describe("Smart Pool", function () {
  let exactlyEnv: DefaultEnv;

  let underlyingTokenDAI: Contract;
  let fixedLenderDAI: Contract;
  let eDAI: Contract;
  let underlyingTokenWBTC: Contract;
  let fixedLenderWBTC: Contract;
  let eWBTC: Contract;
  let bob: SignerWithAddress;
  let john: SignerWithAddress;
  let bobBalancePre = parseUnits("2000");
  let johnBalancePre = parseUnits("2000");

  const mockedTokens = new Map([
    [
      "DAI",
      {
        decimals: 18,
        collateralRate: parseUnits("0.8"),
        usdPrice: parseUnits("1"),
      },
    ],
    [
      "WBTC",
      {
        decimals: 8,
        collateralRate: parseUnits("0.6", 18),
        usdPrice: parseUnits("60000"),
      },
    ],
  ]);

  beforeEach(async () => {
    [, bob, john] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create({ mockedTokens });
    eDAI = exactlyEnv.getEToken("DAI");
    underlyingTokenDAI = exactlyEnv.getUnderlying("DAI");
    fixedLenderDAI = exactlyEnv.getFixedLender("DAI");

    eWBTC = exactlyEnv.getEToken("WBTC");
    underlyingTokenWBTC = exactlyEnv.getUnderlying("WBTC");
    fixedLenderWBTC = exactlyEnv.getFixedLender("WBTC");

    // From Owner to User
    await underlyingTokenDAI.transfer(bob.address, bobBalancePre);
    await underlyingTokenWBTC.transfer(bob.address, parseUnits("1", 8));
    await underlyingTokenDAI.transfer(john.address, johnBalancePre);
  });

  describe("GIVEN bob and jhon have 2000DAI in balance, AND deposit 1000DAI each", () => {
    beforeEach(async () => {
      await underlyingTokenDAI
        .connect(bob)
        .approve(fixedLenderDAI.address, bobBalancePre);
      await underlyingTokenDAI
        .connect(john)
        .approve(fixedLenderDAI.address, johnBalancePre);

      await fixedLenderDAI.connect(bob).depositToSmartPool(parseUnits("1000"));
      await fixedLenderDAI.connect(john).depositToSmartPool(parseUnits("1000"));
    });
    it("THEN balance of DAI in contract is 2000", async () => {
      let balanceOfAssetInContract = await underlyingTokenDAI.balanceOf(
        fixedLenderDAI.address
      );

      expect(balanceOfAssetInContract).to.equal(parseUnits("2000"));
    });
    it("THEN balance of eDAI in BOB's address is 1000", async () => {
      let balanceOfETokenInUserAddress = await eDAI.balanceOf(bob.address);

      expect(balanceOfETokenInUserAddress).to.equal(parseUnits("1000"));
    });
    it("AND WHEN bob deposits 100DAI more, THEN event DepositToSmartPool is emitted", async () => {
      await expect(
        fixedLenderDAI.connect(bob).depositToSmartPool(parseUnits("100"))
      ).to.emit(fixedLenderDAI, "DepositToSmartPool");
    });
    describe("AND bob withdraws 500DAI", () => {
      beforeEach(async () => {
        let amountToWithdraw = parseUnits("500");
        await fixedLenderDAI
          .connect(bob)
          .withdrawFromSmartPool(amountToWithdraw);
      });
      it("THEN balance of DAI in contract is 1500", async () => {
        let balanceOfAssetInContract = await underlyingTokenDAI.balanceOf(
          fixedLenderDAI.address
        );

        expect(balanceOfAssetInContract).to.equal(parseUnits("1500"));
      });
      it("THEN balance of eDAI in BOB's address is 500", async () => {
        let balanceOfETokenInUserAddress = await eDAI.balanceOf(bob.address);

        expect(balanceOfETokenInUserAddress).to.equal(parseUnits("500"));
      });
      it("AND WHEN bob withdraws 100DAI more, THEN event WithdrawFromSmartPool is emitted", async () => {
        await expect(
          fixedLenderDAI.connect(bob).withdrawFromSmartPool(parseUnits("100"))
        ).to.emit(fixedLenderDAI, "WithdrawFromSmartPool");
      });
      it("AND WHEN bob wants to withdraw 600DAI more, THEN it reverts because his eDAI balance is not enough", async () => {
        await expect(
          fixedLenderDAI.connect(bob).withdrawFromSmartPool(parseUnits("600"))
        ).to.be.revertedWith("ERC20: burn amount exceeds balance");
      });
      it("AND WHEN bob wants to withdraw all the assets, THEN he doesn't need to especifically set the amount", async () => {
        await expect(
          fixedLenderDAI
            .connect(bob)
            .withdrawFromSmartPool(ethers.constants.MaxUint256)
        ).to.not.be.reverted;
        const bobBalancePost = await underlyingTokenDAI.balanceOf(bob.address);
        expect(bobBalancePre).to.equal(bobBalancePost);
      });
    });
  });

  describe("GIVEN bob has 1WBTC in balance, AND deposit 1WBTC", () => {
    beforeEach(async () => {
      let bobBalance = parseUnits("1", 8);
      await underlyingTokenWBTC
        .connect(bob)
        .approve(fixedLenderWBTC.address, bobBalance);

      await fixedLenderWBTC.connect(bob).depositToSmartPool(parseUnits("1", 8));
    });
    it("THEN balance of WBTC in contract is 1", async () => {
      let balanceOfAssetInContract = await underlyingTokenWBTC.balanceOf(
        fixedLenderWBTC.address
      );

      expect(balanceOfAssetInContract).to.equal(parseUnits("1", 8));
    });
    it("THEN balance of eWBTC in BOB's address is 1", async () => {
      let balanceOfETokenInUserAddress = await eWBTC.balanceOf(bob.address);

      expect(balanceOfETokenInUserAddress).to.equal(parseUnits("1", 8));
    });
  });

  describe("GIVEN an underlying token with 10% comission", () => {
    beforeEach(async () => {
      await underlyingTokenDAI.setCommission(parseUnits("0.1"));
      await underlyingTokenDAI.transfer(john.address, parseUnits("10000"));
    });

    describe("WHEN depositing 1000 DAI on a smart pool", () => {
      const amount = parseUnits("1000");

      beforeEach(async () => {
        await underlyingTokenDAI
          .connect(john)
          .approve(fixedLenderDAI.address, amount);
        await fixedLenderDAI.connect(john).depositToSmartPool(amount);
      });

      it("THEN the user receives 900 on smart pool deposit", async () => {
        const supplied = await exactlyEnv
          .getEToken("DAI")
          .connect(john)
          .balanceOf(john.address);
        expect(supplied).to.eq(
          amount.mul(parseUnits("0.9")).div(parseUnits("1"))
        );
      });

      describe("AND WHEN withdrawing 900 DAI from a smart pool", () => {
        const amount = parseUnits("900");
        let balancePre: BigNumber;
        beforeEach(async () => {
          balancePre = await underlyingTokenDAI
            .connect(john)
            .balanceOf(john.address);
          await fixedLenderDAI.connect(john).withdrawFromSmartPool(amount);
        });

        it("THEN the user receives 810 on his wallet", async () => {
          const balancePost = await underlyingTokenDAI
            .connect(john)
            .balanceOf(john.address);
          expect(balancePost.sub(balancePre)).to.eq(parseUnits("810"));
        });
      });
    });
  });
});
