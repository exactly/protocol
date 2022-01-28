import { expect } from "chai";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { errorGeneric, ProtocolError } from "./exactlyUtils";
import { DefaultEnv } from "./defaultEnv";

describe("InterestRateModel", () => {
  let exactlyEnv: DefaultEnv;

  let interestRateModel: Contract;
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
    exactlyEnv = await DefaultEnv.create({
      useRealInterestRateModel: true,
    });

    interestRateModel = exactlyEnv.interestRateModel;
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await exactlyEnv.takeSnapshot();
  });

  afterEach(async () => {
    await exactlyEnv.revertSnapshot(snapshot);
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
