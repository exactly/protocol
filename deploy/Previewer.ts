import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  await deploy("Previewer", {
    args: [(await get("Auditor")).address],
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
