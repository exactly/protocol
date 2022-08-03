import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  const args = [(await get("Auditor")).address];

  await validateUpgrade("Previewer", args);

  await deploy("Previewer", {
    args,
    proxy: {
      proxyContract: "ERC1967Proxy",
      proxyArgs: ["{implementation}", "{data}"],
      execute: {
        init: { methodName: "initialize", args: [] },
      },
    },
    from: deployer,
    log: true,
  });
};

func.tags = ["Previewer"];
func.dependencies = ["Auditor"];

export default func;
