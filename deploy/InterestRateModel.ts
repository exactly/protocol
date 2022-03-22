import type { DeployFunction } from "hardhat-deploy/types";
import type { InterestRateModel, TimelockController } from "../types";
import timelockPropose from "./.utils/timelockPropose";

const func: DeployFunction = async ({
  config: {
    finance: {
      interestRateModel: { curveA, curveB, maxUtilizationRate, smartPoolRate },
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
  const curveArgs = [parseUnits(String(curveA)), parseUnits(String(curveB)), parseUnits(String(maxUtilizationRate))];
  const args = curveArgs.slice();
  args.push(parseUnits(String(smartPoolRate)));

  await deploy("InterestRateModel", { skipIfAlreadyDeployed: true, args, from: deployer, log: true });

  const interestRateModel = await getContract<InterestRateModel>("InterestRateModel", deployer);
  if ((await interestRateModel.getCurveParameters()).some((param, i) => !param.eq(curveArgs[i]))) {
    const timelock = await getContract<TimelockController>("TimelockController", deployer);
    await timelockPropose(timelock, interestRateModel, "setCurveParameters", curveArgs);
  }
  if (!(await interestRateModel.spFeeRate()).eq(parseUnits(String(smartPoolRate)))) {
    const timelock = await getContract<TimelockController>("TimelockController", deployer);
    await timelockPropose(timelock, interestRateModel, "setSPFeeRate", [parseUnits(String(smartPoolRate))]);
  }
};

func.tags = ["InterestRateModel"];
func.dependencies = ["TimelockController"];

export default func;
