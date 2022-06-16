import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({
  network: {
    config: { priceExpiration = 7 * 86_400 },
  },
  deployments: { deploy },
  getNamedAccounts,
}) => {
  const { deployer } = await getNamedAccounts();
  await deploy("ExactlyOracle", { skipIfAlreadyDeployed: true, args: [priceExpiration], from: deployer, log: true });
};

func.tags = ["ExactlyOracle"];

export default func;
