import type { DeployFunction } from "hardhat-deploy/types";
import type { InterestRateModel } from "../types";
import timelockPropose from "./.utils/timelockPropose";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({
  config: {
    finance: {
      interestRateModel: {
        fixedCurve: fixedCurveNumber,
        fixedFullUtilization: fixedFullUtilizationNumber,
        floatingCurve: floatingCurveNumber,
        floatingFullUtilization: floatingFullUtilizationNumber,
      },
    },
  },
  ethers: {
    utils: { parseUnits },
    getContract,
  },
  deployments: { deploy },
  getNamedAccounts,
}) => {
  const { deployer } = await getNamedAccounts();
  const fixedCurve = [
    parseUnits(String(fixedCurveNumber.a)),
    parseUnits(String(fixedCurveNumber.b)),
    parseUnits(String(fixedCurveNumber.maxUtilization)),
  ];
  const fixedFullUtilization = parseUnits(String(fixedFullUtilizationNumber));
  const floatingCurve = [
    parseUnits(String(floatingCurveNumber.a)),
    parseUnits(String(floatingCurveNumber.b)),
    parseUnits(String(floatingCurveNumber.maxUtilization)),
  ];
  const floatingFullUtilization = parseUnits(String(floatingFullUtilizationNumber));

  await tenderlify(
    "InterestRateModel",
    await deploy("InterestRateModel", {
      skipIfAlreadyDeployed: true,
      args: [fixedCurve, fixedFullUtilization, floatingCurve, floatingFullUtilization],
      from: deployer,
      log: true,
    }),
  );

  const irm = await getContract<InterestRateModel>("InterestRateModel", deployer);
  if (
    !(await irm.fixedFullUtilization()).eq(fixedFullUtilization) ||
    (await irm.fixedCurve()).some((param, i) => !param.eq(fixedCurve[i]))
  ) {
    await timelockPropose(irm, "setFixedParameters", [fixedCurve, fixedFullUtilization]);
  }
  if (
    !(await irm.floatingFullUtilization()).eq(floatingFullUtilization) ||
    (await irm.floatingCurve()).some((param, i) => !param.eq(floatingCurve[i]))
  ) {
    await timelockPropose(irm, "setFloatingCurveParameters", [floatingCurve, floatingFullUtilization]);
  }
};

func.tags = ["InterestRateModel"];
func.dependencies = ["TimelockController"];

export default func;
