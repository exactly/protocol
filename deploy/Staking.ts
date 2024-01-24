import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [
    { address: exa },
    { address: weth },
    { address: pool },
    { address: socket },
    { address: permit2 },
    { address: timelock },
    { deployer },
  ] = await Promise.all([
    get("EXA"),
    get("WETH"),
    get("EXAPool"),
    get("SocketGateway"),
    get("Permit2"),
    get("TimelockController"),
    getNamedAccounts(),
  ]);

  await validateUpgrade(
    "Swapper",
    { args: [exa, weth, pool, socket, permit2], envKey: "SWAPPER" },
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

func.tags = ["Staking"];
func.dependencies = ["EXA", "Governance", "Rewards", "Assets"];
func.skip = async ({ deployments }) => !(await deployments.getOrNull("EXAGauge"));

export default func;
