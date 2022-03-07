import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy }, getNamedAccounts }) => {
  const { deployer, multisig } = await getNamedAccounts();
  await deploy("TimelockController", {
    args: [
      deployer !== multisig ? 86_400 * 7 : 60, // min timelock delay in seconds
      [multisig, deployer], // proposers addresses
      [multisig], // executors addresses
    ],
    from: deployer,
    log: true,
  });
};

func.tags = ["TimelockController"];

export default func;
