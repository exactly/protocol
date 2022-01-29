import { expect } from "chai";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { ExaTime } from "./exactlyUtils";
import { DefaultEnv } from "./defaultEnv";

describe("InterestRateModel", () => {
  let exactlyEnv: DefaultEnv;
  const exaTime = new ExaTime();

  let interestRateModel: Contract;
  let snapshot: any;

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
    const A = parseUnits("0.037125"); // A parameter for the curve
    const B = parseUnits("0.01625"); // B parameter for the curve
    const maxUtilizationRate = parseUnits("1.2"); // Maximum utilization rate
    const penaltyRate = parseUnits("0.025"); // Penalty rate

    await interestRateModel.setParameters(
      A,
      B,
      maxUtilizationRate,
      penaltyRate
    );
    expect(await interestRateModel.curveParameterA()).to.be.equal(A);
    expect(await interestRateModel.curveParameterB()).to.be.equal(B);
    expect(await interestRateModel.maxUtilizationRate()).to.be.equal(
      maxUtilizationRate
    );
    expect(await interestRateModel.penaltyRate()).to.be.equal(penaltyRate);
  });

  });
});
