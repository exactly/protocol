import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("PoolLib", {
    libraries: { TSUtils: (await get("TSUtils")).address },
    from: deployer,
    log: true,
  });
};

func.tags = ["PoolLib"];
func.dependencies = ["TSUtils"];

export default func;
