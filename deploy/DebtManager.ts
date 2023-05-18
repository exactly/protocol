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
    "DebtManager",
    await deploy("DebtManager", {
      skipIfAlreadyDeployed: !JSON.parse(env.DEPLOY_DEBT_MANAGER ?? "false"),
      args: [auditor, balancerVault],
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["DebtManager"];
func.dependencies = ["Auditor", "Markets", "BalancerVault"];

export default func;
