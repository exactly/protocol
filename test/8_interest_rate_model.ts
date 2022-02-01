import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { errorGeneric, ProtocolError } from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { parseEther } from "ethers/lib/utils";
import { DefaultEnv } from "./defaultEnv";

describe("InterestRateModel", () => {
  let exactlyEnv: DefaultEnv;

  let underlyingToken: Contract;
  let eth: Contract;
  let interestRateModel: Contract;
  let mariaUser: SignerWithAddress;

  let maturityPool = {
    borrowed: 0,
    supplied: 0,
    suppliedSP: 0,
    unassignedEarnings: 0,
    earningsMP: 0,
    earningsSP: 0,
    lastAccrue: 0,
  };

  beforeEach(async () => {
    // we ignore the first item: owner
    [, mariaUser] = await ethers.getSigners();

    exactlyEnv = await DefaultEnv.create({
      useRealInterestRateModel: true,
    });

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    eth = exactlyEnv.getUnderlying("ETH");

    interestRateModel = exactlyEnv.interestRateModel;
    // From Owner to User
    underlyingToken.transfer(mariaUser.address, parseUnits("1000000"));
    eth.transfer(mariaUser.address, parseEther("100"));
  });

  describe("GIVEN a set of parameters", async () => {
    let maturitySlopeRate: BigNumber; // Maturity pool slope rate
    let smartPoolRate: BigNumber; // Smart pool slope rate
    let highURSlopeRate: BigNumber; // High UR slope rate
    let slopeChangeRate: BigNumber; // Slope change rate
    let baseRate: BigNumber; // Base rate
    let penaltyRate: BigNumber; // Penalty rate

    beforeEach(async () => {
      maturitySlopeRate = parseUnits("0.07"); // Maturity pool slope rate
      smartPoolRate = parseUnits("0.07"); // Smart pool slope rate
      highURSlopeRate = parseUnits("0.4"); // High UR slope rate
      slopeChangeRate = parseUnits("0.8"); // Slope change rate
      baseRate = parseUnits("0.02"); // Base rate
      penaltyRate = parseUnits("0.022"); // Penalty rate
    });

    describe("WHEN the owner calls setParameters function", async () => {
      beforeEach(async () => {
        await interestRateModel.setParameters(
          maturitySlopeRate,
          smartPoolRate,
          highURSlopeRate,
          slopeChangeRate,
          baseRate,
          penaltyRate
        );
      });

      it("THEN all the parameters should be reflected in the contract", async () => {
        expect(await interestRateModel.mpSlopeRate()).to.be.equal(
          maturitySlopeRate
        );
        expect(await interestRateModel.spSlopeRate()).to.be.equal(
          smartPoolRate
        );
        expect(await interestRateModel.spHighURSlopeRate()).to.be.equal(
          highURSlopeRate
        );
        expect(await interestRateModel.slopeChangeRate()).to.be.equal(
          slopeChangeRate
        );
        expect(await interestRateModel.baseRate()).to.be.equal(baseRate);
        expect(await interestRateModel.penaltyRate()).to.be.equal(penaltyRate);
      });
    });

    describe("getYieldForDeposit", async () => {
      it("WHEN supply of smart pool is 100, earnings unassigned are 100, and amount deposited is 100, then yield is 50", async () => {
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("100"),
            parseUnits("100"),
            parseUnits("100")
          )
        ).to.equal(parseUnits("50"));
      });

      it("WHEN supply of smart pool is 0, earnings unassigned are 0, and amount deposited is 100, then yield is 0", async () => {
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("0"),
            parseUnits("0"),
            parseUnits("100")
          )
        ).to.equal(parseUnits("0"));
      });

      it("WHEN supply of smart pool is 0, earnings unassigned are 100, and amount deposited is 100, then yield is 100", async () => {
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("0"),
            parseUnits("100"),
            parseUnits("100")
          )
        ).to.equal(parseUnits("100"));
      });

      it("WHEN supply of smart pool is 100, earnings unassigned are 100, and amount deposited is 0, then yield is 0", async () => {
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("100"),
            parseUnits("100"),
            parseUnits("0")
          )
        ).to.equal(parseUnits("0"));
      });

      it("WHEN supply of smart pool is 0, earnings unassigned are 100, and amount deposited is 0, then yield is 0", async () => {
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("0"),
            parseUnits("100"),
            parseUnits("0")
          )
        ).to.equal(parseUnits("0"));
      });

      it("WHEN supply of smart pool is 100, earnings unassigned are 0, and amount deposited is 100, then yield is 0", async () => {
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("100"),
            parseUnits("0"),
            parseUnits("100")
          )
        ).to.equal(parseUnits("0"));
      });
    });

    it("WHEN any user calls getRateToBorrow on an invalid pool id, THEN it should revert with INVALID_POOL_ID", async () => {
      await expect(
        interestRateModel.getRateToBorrow(
          parseUnits("123", 0),
          maturityPool,
          parseUnits("1000"),
          parseUnits("1000000"),
          false
        )
      ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
    });

    it("WHEN a user calls setParameters function", async () => {
      await expect(
        interestRateModel
          .connect(mariaUser)
          .setParameters(
            maturitySlopeRate,
            smartPoolRate,
            highURSlopeRate,
            slopeChangeRate,
            baseRate,
            penaltyRate
          )
      ).to.be.revertedWith("AccessControl");
    });
  });
});
