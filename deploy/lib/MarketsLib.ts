import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("MarketsLib", { from: deployer, log: true });
};

func.tags = ["MarketsLib"];

export default func;
