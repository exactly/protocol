import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("MarketsLib", {
    libraries: { DecimalMath: (await get("DecimalMath")).address },
    from: deployer,
    log: true,
  });
};

func.tags = ["MarketsLib"];
func.dependencies = ["DecimalMath"];

export default func;
