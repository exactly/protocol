import { expect } from "chai";
import { ethers } from "hardhat";
import type { InterestRateModel__factory } from "../../types";

const { ZeroAddress, parseUnits, getContractFactory, provider } = ethers;

describe("InterestRateModel", () => {
  let snapshot: string;
  let irmFactory: InterestRateModel__factory;

  before(async () => {
    irmFactory = await getContractFactory("InterestRateModel");
  });

  beforeEach(async () => {
    snapshot = await provider.send("evm_snapshot", []);
  });

  afterEach(() => provider.send("evm_revert", [snapshot]));

  describe("setting different curve parameters", () => {
    it("WHEN deploying a contract with A and B parameters yielding an invalid FIXED curve THEN it reverts", async () => {
      // - U_{b}: 0.9
      // - U_{max}: 1.2
      // - R_{0}: -0.01
      // - R_{b}: 0.22

      // A = ((Umax*(Umax-Ub))/Ub)*(Rb-R0)
      // A = .09200000000000000000

      // B = ((Umax/Ub)*R0) + (1-(Umax/Ub))*Rb
      // B = -.08666666666666666666
      const minRate = parseUnits("0.035");
      const naturalRate = parseUnits("0.08");
      const maxUtilization = parseUnits("1.2"); // Maximum utilization rate
      const naturalUtilization = parseUnits("0.75");
      const growthSpeed = parseUnits("2.5");
      const sigmoidSpeed = parseUnits("2.5");
      const spreadFactor = parseUnits("0.2");
      const maturitySpeed = parseUnits("0.5");
      const timePreference = parseUnits("0.01");
      const fixedAllocation = parseUnits("0");
      const maxRate = parseUnits("0.1");
      const maturityDurationSpeed = parseUnits("0.5");
      const durationThreshold = parseUnits("0.2");
      const durationGrowthLaw = parseUnits("1");
      const penaltyDurationFactor = parseUnits("0.8333");
      const fixedBorrowThreshold = parseUnits("0.6");
      const curveFactor = parseUnits("0.5");
      const minThresholdFactor = parseUnits("0.25");

      await expect(
        irmFactory.deploy(
          {
            minRate,
            naturalRate,
            maxUtilization,
            naturalUtilization,
            growthSpeed,
            sigmoidSpeed,
            spreadFactor,
            maturitySpeed,
            timePreference,
            fixedAllocation,
            maxRate,
            maturityDurationSpeed,
            durationThreshold,
            durationGrowthLaw,
            penaltyDurationFactor,
            fixedBorrowThreshold,
            curveFactor,
            minThresholdFactor,
          },
          ZeroAddress,
        ),
      ).to.be.reverted;
    });

    it("WHEN deploying a contract with A and B parameters yielding an invalid floating curve THEN it reverts", async () => {
      const minRate = parseUnits("0");
      const naturalRate = parseUnits("0");
      const maxUtilization = parseUnits("1.2"); // Maximum utilization rate
      const naturalUtilization = parseUnits("0.7");
      const sigmoidSpeed = parseUnits("2.5");
      const growthSpeed = parseUnits("2.5");
      const maxRate = parseUnits("0.1");
      const spreadFactor = parseUnits("0.2");
      const timePreference = parseUnits("0");
      const maturitySpeed = parseUnits("0.5");
      const fixedAllocation = parseUnits("0.6");
      const maturityDurationSpeed = parseUnits("0.5");
      const durationThreshold = parseUnits("0.2");
      const durationGrowthLaw = parseUnits("1");
      const penaltyDurationFactor = parseUnits("0.8333");
      const fixedBorrowThreshold = parseUnits("0.6");
      const curveFactor = parseUnits("0.5");
      const minThresholdFactor = parseUnits("0.25");

      await expect(
        irmFactory.deploy(
          {
            minRate,
            naturalRate,
            maxUtilization,
            naturalUtilization,
            growthSpeed,
            sigmoidSpeed,
            spreadFactor,
            maturitySpeed,
            timePreference,
            fixedAllocation,
            maxRate,
            maturityDurationSpeed,
            durationThreshold,
            durationGrowthLaw,
            penaltyDurationFactor,
            fixedBorrowThreshold,
            curveFactor,
            minThresholdFactor,
          },
          ZeroAddress,
        ),
      ).to.be.reverted;
    });
  });
});
