import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [{ address: auditor }, { deployer }] = await Promise.all([get("Auditor"), getNamedAccounts()]);
  await validateUpgrade("RatePreviewer", { args: [auditor], envKey: "RATE_PREVIEWER" }, async (name, opts) =>
    deploy(name, {
      ...opts,
      proxy: { proxyContract: "TransparentUpgradeableProxy" },
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["RatePreviewer"];
func.dependencies = ["Auditor"];

export default func;
