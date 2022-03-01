import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ExaTime, errorGeneric, ProtocolError } from "./exactlyUtils";
import { DefaultEnv } from "./defaultEnv";

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
  const bobBalancePre = parseUnits("2000");
  const johnBalancePre = parseUnits("2000");
  const exaTime: ExaTime = new ExaTime();
  const nextPoolId: number = exaTime.nextPoolID();

  beforeEach(async () => {
    [, bob, john] = await ethers.getSigners();

    exactlyEnv = await DefaultEnv.create({});
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
  describe("timelock", () => {
    describe("GIVEN bob has 2000DAI in balance", () => {
      beforeEach(async () => {
        await underlyingTokenDAI
          .connect(bob)
          .approve(fixedLenderDAI.address, bobBalancePre);
      });

      describe("AND GIVEN a pending tx for a deposit", () => {
        beforeEach(async () => {
          await ethers.provider.send("evm_setAutomine", [false]);
          await ethers.provider.send("evm_mine", []);
          await fixedLenderDAI
            .connect(bob)
            .depositToSmartPool(parseUnits("1000"));
        });
        it("WHEN also withdrawing in the same block, THEN it reverts because the tokens are locked", async () => {
          await ethers.provider.send("evm_setAutomine", [true]);
          const tx = fixedLenderDAI
            .connect(bob)
            .withdrawFromSmartPool(parseUnits("1000"));
          await expect(tx).to.be.revertedWith(
            errorGeneric(ProtocolError.SMART_POOL_FUNDS_LOCKED)
          );
          const balanceOfETokenInUserAddress = await eDAI.balanceOf(
            bob.address
          );
          // ensure the deposit tx went through
          expect(balanceOfETokenInUserAddress).to.eq(parseUnits("1000"));
        });
        afterEach(async () => {
          await ethers.provider.send("evm_setAutomine", [true]);
        });
      });

      describe("AND GIVEN a pending tx for a transfer to john", () => {
        beforeEach(async () => {
          await fixedLenderDAI
            .connect(bob)
            .depositToSmartPool(parseUnits("1000"));
          await ethers.provider.send("evm_setAutomine", [false]);
          await ethers.provider.send("evm_mine", []);
          await eDAI.connect(bob).transfer(john.address, parseUnits("1000"));
        });
        it("WHEN john wants to withdraw in the same block, THEN it reverts because the tokens are locked", async () => {
          await ethers.provider.send("evm_setAutomine", [true]);
          const tx = fixedLenderDAI
            .connect(john)
            .withdrawFromSmartPool(parseUnits("1000"));
          await expect(tx).to.be.revertedWith(
            errorGeneric(ProtocolError.SMART_POOL_FUNDS_LOCKED)
          );
          const balanceOfETokenInUserAddress = await eDAI.balanceOf(
            john.address
          );
          // ensure the deposit tx went through
          expect(balanceOfETokenInUserAddress).to.eq(parseUnits("1000"));
        });
        afterEach(async () => {
          await ethers.provider.send("evm_setAutomine", [true]);
        });
      });
    });
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

  describe("GIVEN bob deposits 100 DAI (collateralization rate 80%)", () => {
    beforeEach(async () => {
      exactlyEnv.switchWallet(bob);
      await exactlyEnv.depositSP("DAI", "100");
      // we add liquidity to the maturity
      await exactlyEnv.depositMP("DAI", nextPoolId, "60");
    });
    it("WHEN trying to transfer to another user the entire position (100 eDAI) THEN it should not revert", async () => {
      await expect(eDAI.connect(bob).transfer(john.address, parseUnits("100")))
        .to.not.be.reverted;
    });
    describe("AND GIVEN bob borrows 60 DAI from a maturity", () => {
      beforeEach(async () => {
        await exactlyEnv.borrowMP("DAI", nextPoolId, "60");
      });
      it("WHEN trying to transfer to another user the entire position (100 eDAI) without repaying first THEN it reverts with INSUFFICIENT_LIQUIDITY", async () => {
        await expect(
          eDAI.connect(bob).transfer(john.address, parseUnits("100"))
        ).to.be.revertedWith("InsufficientLiquidity()");
      });
      it("AND WHEN trying to transfer a small amount that doesnt cause a shortfall (10 eDAI, should move collateralization from 60% to 66%) without repaying first THEN it is allowed", async () => {
        await expect(eDAI.connect(bob).transfer(john.address, parseUnits("10")))
          .to.not.be.reverted;
      });
      it("WHEN trying to withdraw the entire position (100 DAI) without repaying first THEN it reverts with INSUFFICIENT_LIQUIDITY", async () => {
        await expect(exactlyEnv.withdrawSP("DAI", "100")).to.be.revertedWith(
          "InsufficientLiquidity()"
        );
      });
      it("AND WHEN trying to withdraw a small amount that doesnt cause a shortfall (10 DAI, should move collateralization from 60% to 66%) without repaying first THEN it is allowed", async () => {
        await expect(exactlyEnv.withdrawSP("DAI", "10")).to.not.be.reverted;
      });
    });
  });

  describe("GIVEN an underlying token with 10% comission", () => {
    beforeEach(async () => {
      await underlyingTokenDAI.setCommission(parseUnits("0.1"));
      await underlyingTokenDAI.transfer(john.address, parseUnits("10000"));
    });

    describe("WHEN depositing 1000 DAI on a smart pool", () => {
      const amount = parseUnits("1000");
      let tx: any;

      beforeEach(async () => {
        await underlyingTokenDAI
          .connect(john)
          .approve(fixedLenderDAI.address, amount);
        tx = fixedLenderDAI.connect(john).depositToSmartPool(amount);
      });

      it("THEN the transaction reverts with INVALID_TOKEN_FEE", async () => {
        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.INVALID_TOKEN_FEE)
        );
      });
    });
  });
});
