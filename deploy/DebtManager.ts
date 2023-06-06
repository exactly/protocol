import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [{ address: auditor }, { address: permit2 }, { address: balancerVault }, { address: timelock }, { deployer }] =
    await Promise.all([
      get("Auditor"),
      get("Permit2"),
      get("BalancerVault"),
      get("TimelockController"),
      getNamedAccounts(),
    ]);

  await validateUpgrade(
    "DebtManager",
    { args: [auditor, permit2, balancerVault], envKey: "DEBT_MANAGER" },
    async (name, opts) =>
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
func.dependencies = ["TimelockController", "Auditor", "Markets", "BalancerVault", "Permit2"];

export default func;
