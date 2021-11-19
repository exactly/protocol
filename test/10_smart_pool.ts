import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  ProtocolError,
  errorGeneric,
  DefaultEnv,
  ExactlyEnv,
} from "./exactlyUtils";

describe("Smart Pool", function () {
  let exactlyEnv: DefaultEnv;

  let underlyingToken: Contract;
  let fixedLender: Contract;
  let eDAI: Contract;
  let bob: SignerWithAddress;
  let john: SignerWithAddress;

  const mockedTokens = new Map([
    [
      "DAI",
      {
        decimals: 18,
        collateralRate: parseUnits("0.8"),
        usdPrice: parseUnits("1"),
      },
    ],
  ]);

  beforeEach(async () => {
    [bob, john] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(mockedTokens);
    eDAI = exactlyEnv.getEToken("DAI");

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    fixedLender = exactlyEnv.getFixedLender("DAI");
    await eDAI.setFixedLender(fixedLender.address);

    // From Owner to User
    await underlyingToken.transfer(bob.address, parseUnits("2000"));
    await underlyingToken.transfer(john.address, parseUnits("2000"));
  });

  describe("GIVEN bob has 2000DAI in balance, AND deposits 1000DAI", () => {
    beforeEach(async () => {
      let bobBalance = parseUnits("2000");
      let johnBalance = parseUnits("2000");
      const fixedLenderJohn = fixedLender.connect(john);
      await underlyingToken.approve(fixedLender.address, bobBalance);

      const underlyingTokenUser = underlyingToken.connect(john);
      await underlyingTokenUser.approve(fixedLender.address, johnBalance);

      await fixedLenderJohn.depositToSmartPool(parseUnits("1000"));
      await fixedLender.depositToSmartPool(parseUnits("1000"));
    });
    it("THEN balance of DAI in contract is 2000", async () => {
      let balanceOfAssetInContract = await underlyingToken.balanceOf(
        fixedLender.address
      );

      expect(balanceOfAssetInContract).to.equal(parseUnits("2000"));
    });
    it("THEN balance of eDAI in BOB's address is 1000", async () => {
      let balanceOfETokenInUserAddress = await eDAI.balanceOf(bob.address);

      expect(balanceOfETokenInUserAddress).to.equal(parseUnits("1000"));
    });
    it("AND WHEN bob deposits 100DAI more, THEN event DepositToSmartPool is emitted", async () => {
      await expect(fixedLender.depositToSmartPool(parseUnits("100"))).to.emit(
        fixedLender,
        "DepositToSmartPool"
      );
    });
    describe("AND bob withdraws 500DAI", () => {
      beforeEach(async () => {
        let amountToWithdraw = parseUnits("500");
        await fixedLender.withdrawFromSmartPool(amountToWithdraw);
      });
      it("THEN balance of DAI in contract is 1500", async () => {
        let balanceOfAssetInContract = await underlyingToken.balanceOf(
          fixedLender.address
        );

        expect(balanceOfAssetInContract).to.equal(parseUnits("1500"));
      });
      it("THEN balance of eDAI in BOB's address is 500", async () => {
        let balanceOfETokenInUserAddress = await eDAI.balanceOf(bob.address);

        expect(balanceOfETokenInUserAddress).to.equal(parseUnits("500"));
      });
      it("AND WHEN bob withdraws 100DAI more, THEN event WithdrawFromSmartPool is emitted", async () => {
        await expect(
          fixedLender.withdrawFromSmartPool(parseUnits("100"))
        ).to.emit(fixedLender, "WithdrawFromSmartPool");
      });
      it("AND WHEN bob wants to withdraw 600DAI more, THEN it reverts because his eDAI balance is not enough", async () => {
        await expect(
          fixedLender.withdrawFromSmartPool(parseUnits("600"))
        ).to.be.revertedWith(
          errorGeneric(ProtocolError.BURN_AMOUNT_EXCEEDS_BALANCE)
        );
      });
    });
  });
});
