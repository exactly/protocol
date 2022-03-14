import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("Auditor", {
    args: [(await get("ExactlyOracle")).address],
    from: deployer,
    log: true,
  });
};

func.tags = ["Auditor"];
func.dependencies = ["ExactlyOracle"];

export default func;
