import { env } from "process";
import type { DeployFunction } from "hardhat-deploy/types";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [{ address: auditor }, { address: balancerVault }, { deployer }] = await Promise.all([
    get("Auditor"),
    get("BalancerVault"),
    getNamedAccounts(),
  ]);

  await tenderlify(
    "Leverager",
    await deploy("Leverager", {
      skipIfAlreadyDeployed: !JSON.parse(env.DEPLOY_LEVERAGER ?? "false"),
      args: [auditor, balancerVault],
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["Leverager"];
func.dependencies = ["Auditor", "Markets", "BalancerVault"];
func.skip = async ({ network }) => !network.config.leverager;

export default func;
