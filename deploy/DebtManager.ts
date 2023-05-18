import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [{ address: timelock }, { address: balancerVault }, { address: auditor }, { deployer }] = await Promise.all([
    get("TimelockController"),
    get("BalancerVault"),
    get("Auditor"),
    getNamedAccounts(),
  ]);

  await validateUpgrade("DebtManager", { args: [auditor, balancerVault], envKey: "DEBT_MANAGER" }, async (name, opts) =>
    deploy(name, {
      ...opts,
      proxy: {
        owner: timelock,
        viaAdminContract: "ProxyAdmin",
        proxyContract: "TransparentUpgradeableProxy",
        execute: {
          init: { methodName: "initialize", args: [] },
        },
      },
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["DebtManager"];
func.dependencies = ["Auditor", "Markets", "BalancerVault"];

export default func;
