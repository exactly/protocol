import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ProtocolError, errorGeneric, ExactlyEnv } from "./exactlyUtils";
import { DefaultEnv } from "./defaultEnv";

describe("Pool accounting (Admin)", () => {
  let laura: SignerWithAddress;
  let defaultEnv: DefaultEnv;

  beforeEach(async () => {
    [, laura] = await ethers.getSigners();
    defaultEnv = await ExactlyEnv.create({});
  });

  describe("GIVEN function calls not being the FixedLender contract", () => {
    it("AND invoking borrowMP, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        defaultEnv
          .getPoolAccounting("DAI")
          .connect(laura)
          .borrowMP(0, laura.address, 0, 0, 0)
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.CALLER_MUST_BE_FIXED_LENDER)
      );
    });

    it("AND invoking withdrawMP, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        defaultEnv
          .getPoolAccounting("DAI")
          .connect(laura)
          .withdrawMP(0, laura.address, 0, 0)
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.CALLER_MUST_BE_FIXED_LENDER)
      );
    });

    it("AND invoking repayMP, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        defaultEnv
          .getPoolAccounting("DAI")
          .connect(laura)
          .repayMP(0, laura.address, 0)
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.CALLER_MUST_BE_FIXED_LENDER)
      );
    });

    it("AND invoking repayMP, THEN it should revert with error CALLER_MUST_BE_FIXED_LENDER", async () => {
      await expect(
        defaultEnv
          .getPoolAccounting("DAI")
          .connect(laura)
          .withdrawMP(0, laura.address, 0, 0)
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.CALLER_MUST_BE_FIXED_LENDER)
      );
    });
  });
});
