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
  const args = [
    parseUnits(String(curveA)),
    parseUnits(String(curveB)),
    parseUnits(String(maxUtilizationRate)),
    parseUnits(String(smartPoolRate)),
  ];
  await deploy("InterestRateModel", { skipIfAlreadyDeployed: true, args, from: deployer, log: true });

  const interestRateModel = await getContract<InterestRateModel>("InterestRateModel", deployer);
  if ((await interestRateModel.getParameters()).some((param, i) => !param.eq(args[i]))) {
    const timelock = await getContract<TimelockController>("TimelockController", deployer);
    await timelockPropose(timelock, interestRateModel, "setParameters", args);
  }
};

func.tags = ["InterestRateModel"];
func.dependencies = ["TimelockController"];

export default func;
