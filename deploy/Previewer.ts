import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("Previewer", {
    from: deployer,
    log: true,
  });
};

func.tags = ["Previewer"];

export default func;
