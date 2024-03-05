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
          viaAdminContract: { name: "ProxyAdmin" },
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
func.dependencies = ["Governance", "Auditor", "Markets", "Balancer", "Permit2"];
func.skip = async ({ network }) => !!network.config.sunset;

export default func;
