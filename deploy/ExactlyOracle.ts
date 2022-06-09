import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("ExactlyOracle", { args: [86_400], from: deployer, log: true });
};

func.tags = ["ExactlyOracle"];

export default func;
