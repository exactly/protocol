import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("Balancer2Vault", {
    skipIfAlreadyDeployed: true,
    contract: "MockBalancerVault",
    from: deployer,
    log: true,
  });
};

func.tags = ["Balancer"];
func.skip = async ({ network }) => !!network.live && network.name === "base";

export default func;
