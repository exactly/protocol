import type { DeployFunction } from "hardhat-deploy/types";
import type { InterestRateModel, TimelockController } from "../types";
import timelockPropose from "./.utils/timelockPropose";

const func: DeployFunction = async ({
  config: {
    finance: {
      interestRateModel: {
        fixedCurveA,
        fixedCurveB,
        fixedMaxUtilization,
        fixedFullUtilization,
        flexibleCurveA,
        flexibleCurveB,
        flexibleMaxUtilization,
        flexibleFullUtilization,
        smartPoolRate,
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
  const fixedCurveArgs = [
    parseUnits(String(fixedCurveA)),
    parseUnits(String(fixedCurveB)),
    parseUnits(String(fixedMaxUtilization)),
    parseUnits(String(fixedFullUtilization)),
  ];
  const flexibleCurveArgs = [
    parseUnits(String(flexibleCurveA)),
    parseUnits(String(flexibleCurveB)),
    parseUnits(String(flexibleMaxUtilization)),
    parseUnits(String(flexibleFullUtilization)),
  ];
  const args = fixedCurveArgs.slice();
  args.push(...flexibleCurveArgs);
  args.push(parseUnits(String(smartPoolRate)));

  await deploy("InterestRateModel", { skipIfAlreadyDeployed: true, args, from: deployer, log: true });

  const interestRateModel = await getContract<InterestRateModel>("InterestRateModel", deployer);
  if ((await interestRateModel.getFixedCurveParameters()).some((param, i) => !param.eq(fixedCurveArgs[i]))) {
    const timelock = await getContract<TimelockController>("TimelockController", deployer);
    await timelockPropose(timelock, interestRateModel, "setFixedCurveParameters", fixedCurveArgs);
  }
  if ((await interestRateModel.getFlexibleCurveParameters()).some((param, i) => !param.eq(flexibleCurveArgs[i]))) {
    const timelock = await getContract<TimelockController>("TimelockController", deployer);
    await timelockPropose(timelock, interestRateModel, "setFlexibleCurveParameters", flexibleCurveArgs);
  }
  if (!(await interestRateModel.spFeeRate()).eq(parseUnits(String(smartPoolRate)))) {
    const timelock = await getContract<TimelockController>("TimelockController", deployer);
    await timelockPropose(timelock, interestRateModel, "setSPFeeRate", [parseUnits(String(smartPoolRate))]);
  }
};

func.tags = ["InterestRateModel"];
func.dependencies = ["TimelockController"];

export default func;
