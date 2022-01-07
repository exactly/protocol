import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { ExactlyEnv, errorGeneric, ProtocolError } from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { parseEther } from "ethers/lib/utils";
import { DefaultEnv } from "./defaultEnv";

describe("InterestRateModel", () => {
  let exactlyEnv: DefaultEnv;

  let underlyingToken: Contract;
  let eth: Contract;
  let interestRateModel: Contract;
  let mariaUser: SignerWithAddress;
  let snapshot: any;

  let maturityPool = {
    borrowed: 0,
    supplied: 0,
    suppliedSP: 0,
    unassignedEarnings: 0,
    earningsSP: 0,
    lastAccrue: 0,
  };

  beforeEach(async () => {
    [mariaUser] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create({
      useRealInterestRateModel: true,
    });

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    eth = exactlyEnv.getUnderlying("ETH");

    interestRateModel = exactlyEnv.interestRateModel;
    // From Owner to User
    underlyingToken.transfer(mariaUser.address, parseUnits("1000000"));
    eth.transfer(mariaUser.address, parseEther("100"));

    // This can be optimized (so we only do it once per file, not per test)
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });

  it("should change parameters", async () => {
    const maturitySlopeRate = parseUnits("0.07"); // Maturity pool slope rate
    const smartPoolRate = parseUnits("0.07"); // Smart pool slope rate
    const highURSlopeRate = parseUnits("0.4"); // High UR slope rate
    const slopeChangeRate = parseUnits("0.8"); // Slope change rate
    const baseRate = parseUnits("0.02"); // Base rate
    const penaltyRate = parseUnits("0.022"); // Penalty rate

    await interestRateModel.setParameters(
      maturitySlopeRate,
      smartPoolRate,
      highURSlopeRate,
      slopeChangeRate,
      baseRate,
      penaltyRate
    );
    expect(await interestRateModel.mpSlopeRate()).to.be.equal(
      maturitySlopeRate
    );
    expect(await interestRateModel.spSlopeRate()).to.be.equal(smartPoolRate);
    expect(await interestRateModel.spHighURSlopeRate()).to.be.equal(
      highURSlopeRate
    );
    expect(await interestRateModel.slopeChangeRate()).to.be.equal(
      slopeChangeRate
    );
    expect(await interestRateModel.baseRate()).to.be.equal(baseRate);
    expect(await interestRateModel.penaltyRate()).to.be.equal(penaltyRate);
  });

  it("should revert on invalid pool id when trying to borrow", async () => {
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
});
