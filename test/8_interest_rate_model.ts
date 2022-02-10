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
    eth = exactlyEnv.getUnderlying("WETH");

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

    describe("getYieldForDeposit with a normal weighter distrubition parameter (100%)", async () => {
      const mpDepositDistributionWeighter = parseUnits("1");

      it("WHEN supply of smart pool is 100, earnings unassigned are 100, and amount deposited is 100, then yield is 50", async () => {
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("100"),
            parseUnits("100"),
            parseUnits("100"),
            mpDepositDistributionWeighter
          )
        ).to.equal(parseUnits("50"));
      });

      it("WHEN supply of smart pool is 0, earnings unassigned are 0, and amount deposited is 100, then yield is 0", async () => {
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("0"),
            parseUnits("0"),
            parseUnits("100"),
            mpDepositDistributionWeighter
          )
        ).to.equal(parseUnits("0"));
      });

      it("WHEN supply of smart pool is 0, earnings unassigned are 100, and amount deposited is 100, then yield is 100", async () => {
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("0"),
            parseUnits("100"),
            parseUnits("100"),
            mpDepositDistributionWeighter
          )
        ).to.equal(parseUnits("100"));
      });

      it("WHEN supply of smart pool is 100, earnings unassigned are 100, and amount deposited is 0, then yield is 0", async () => {
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("100"),
            parseUnits("100"),
            parseUnits("0"),
            mpDepositDistributionWeighter
          )
        ).to.equal(parseUnits("0"));
      });

      it("WHEN supply of smart pool is 100, earnings unassigned are 0, and amount deposited is 100, then yield is 0", async () => {
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("100"),
            parseUnits("0"),
            parseUnits("100"),
            mpDepositDistributionWeighter
          )
        ).to.equal(parseUnits("0"));
      });
    });

    describe("getYieldForDeposit with a custom weighter distribution parameter, smart pool supply of 100, unassigned earnings of 100 and amount deposited of 100", async () => {
      let mpDepositDistributionWeighter: any;

      it("WHEN mpDepositDistributionWeighter is 50%, then yield is 33.3333...", async () => {
        mpDepositDistributionWeighter = parseUnits("0.5");
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("100"),
            parseUnits("100"),
            parseUnits("100"),
            mpDepositDistributionWeighter
          )
        ).to.closeTo(
          parseUnits("33.33333333"),
          parseUnits("0.00000001").toNumber()
        );
      });

      it("WHEN mpDepositDistributionWeighter is 150%, then yield is 60", async () => {
        mpDepositDistributionWeighter = parseUnits("1.5");
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("100"),
            parseUnits("100"),
            parseUnits("100"),
            mpDepositDistributionWeighter
          )
        ).to.equal(parseUnits("60"));
      });

      it("WHEN mpDepositDistributionWeighter is 200%, then yield is 66.6666...", async () => {
        mpDepositDistributionWeighter = parseUnits("2");
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("100"),
            parseUnits("100"),
            parseUnits("100"),
            mpDepositDistributionWeighter
          )
        ).to.closeTo(
          parseUnits("66.66666666"),
          parseUnits("0.00000001").toNumber()
        );
      });

      it("WHEN mpDepositDistributionWeighter is 1000%, then yield is 90.9090...", async () => {
        mpDepositDistributionWeighter = parseUnits("10");
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("100"),
            parseUnits("100"),
            parseUnits("100"),
            mpDepositDistributionWeighter
          )
        ).to.closeTo(
          parseUnits("90.90909090"),
          parseUnits("0.00000001").toNumber()
        );
      });

      it("WHEN mpDepositDistributionWeighter is 10000%, then yield is 99.0099...", async () => {
        mpDepositDistributionWeighter = parseUnits("100");
        expect(
          await interestRateModel.getYieldForDeposit(
            parseUnits("100"),
            parseUnits("100"),
            parseUnits("100"),
            mpDepositDistributionWeighter
          )
        ).to.closeTo(
          parseUnits("99.00990099"),
          parseUnits("0.00000001").toNumber()
        );
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

    it("WHEN an unauthorized user calls setParameters function, THEN it should revert", async () => {
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
