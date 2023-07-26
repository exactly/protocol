import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [
    { address: auditor },
    { address: permit2 },
    { address: balancerVault },
    { address: uniswapFactory },
    { address: timelock },
    { deployer },
  ] = await Promise.all([
    get("Auditor"),
    get("Permit2"),
    get("BalancerVault"),
    get("UniswapV3Factory"),
    get("TimelockController"),
    getNamedAccounts(),
  ]);

  await validateUpgrade(
    "DebtManager",
    { args: [auditor, permit2, balancerVault, uniswapFactory], envKey: "DEBT_MANAGER" },
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
func.dependencies = ["Governance", "Auditor", "Markets", "UniswapV3", "Balancer", "Permit2"];

export default func;
