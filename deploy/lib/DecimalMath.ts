import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("DecimalMath", { from: deployer, log: true });
};

func.tags = ["DecimalMath"];

export default func;
