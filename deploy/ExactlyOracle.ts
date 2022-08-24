import type { DeployFunction } from "hardhat-deploy/types";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({
  ethers: {
    constants: { MaxUint256 },
  },
  network: {
    live,
    config: { priceExpiration = live ? MaxUint256 : 86_400 },
  },
  deployments: { deploy },
  getNamedAccounts,
}) => {
  const { deployer } = await getNamedAccounts();
  await tenderlify(
    "ExactlyOracle",
    await deploy("ExactlyOracle", { skipIfAlreadyDeployed: true, args: [priceExpiration], from: deployer, log: true }),
  );
};

func.tags = ["ExactlyOracle"];

export default func;
