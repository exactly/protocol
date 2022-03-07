import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("Auditor", {
    libraries: {
      MarketsLib: (await get("MarketsLib")).address,
    },
    args: [(await get("ExactlyOracle")).address],
    from: deployer,
    log: true,
  });
};

func.tags = ["Auditor"];
func.dependencies = ["MarketsLib", "ExactlyOracle"];

export default func;
