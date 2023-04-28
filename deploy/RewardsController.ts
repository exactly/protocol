import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [{ address: timelock }, { deployer }] = await Promise.all([get("TimelockController"), getNamedAccounts()]);

  await validateUpgrade("RewardsController", { envKey: "REWARDS", unsafeAllow: ["constructor"] }, async (name, opts) =>
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

func.tags = ["RewardsController"];
func.dependencies = ["ProxyAdmin", "TimelockController"];
func.skip = async ({ network }) =>
  !Object.values(network.config.finance.markets).some(({ rewards }) => Boolean(rewards));

export default func;
