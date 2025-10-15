import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [{ address: auditor }, { address: flashLoaner }, { address: timelock }, { deployer }] = await Promise.all([
    get("Auditor"),
    get("BalancerVault"),
    get("TimelockController"),
    getNamedAccounts(),
  ]);

  await validateUpgrade("DebtRoller", { args: [auditor, flashLoaner], envKey: "DEBT_ROLLER" }, async (name, opts) =>
    deploy(name, {
      ...opts,
      proxy: {
        owner: timelock,
        viaAdminContract: { name: "ProxyAdmin" },
        proxyContract: "TransparentUpgradeableProxy",
        execute: { init: { methodName: "initialize", args: [] } },
      },
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["DebtRoller"];
func.dependencies = ["Governance", "Auditor", "Markets", "Balancer"];
func.skip = async ({ network }) => !!network.config.sunset;

export default func;
