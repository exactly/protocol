import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("TSUtils", { from: deployer, log: true });
};

func.tags = ["TSUtils"];

export default func;
