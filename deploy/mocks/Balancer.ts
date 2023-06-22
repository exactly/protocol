import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("BalancerVault", {
    skipIfAlreadyDeployed: true,
    contract: "MockBalancerVault",
    from: deployer,
    log: true,
  });
};

func.tags = ["Balancer"];

export default func;
