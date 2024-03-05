import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [{ address: auditor }, { address: marketWETH }, { address: timelock }, { deployer }] = await Promise.all([
    get("Auditor"),
    get("MarketWETH"),
    get("TimelockController"),
    getNamedAccounts(),
  ]);

  await validateUpgrade(
    "InstallmentsRouter",
    { args: [auditor, marketWETH], envKey: "INSTALLMENTS" },
    async (name, opts) =>
      deploy(name, {
        ...opts,
        proxy: {
          owner: timelock,
          viaAdminContract: { name: "ProxyAdmin" },
          proxyContract: "TransparentUpgradeableProxy",
        },
        from: deployer,
        log: true,
      }),
  );
};

func.tags = ["Installments"];
func.dependencies = ["Auditor", "Markets"];
func.skip = async ({ network }) => !!network.config.sunset;

export default func;
