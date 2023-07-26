import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [
    { address: exa },
    { address: weth },
    { address: pool },
    { address: gauge },
    { address: rewards },
    { address: timelock },
    { deployer },
  ] = await Promise.all([
    get("EXA"),
    get("WETH"),
    get("EXAPool"),
    get("EXAGauge"),
    get("RewardsController"),
    get("TimelockController"),
    getNamedAccounts(),
  ]);

  await validateUpgrade("Swapper", { args: [exa, weth, pool], envKey: "SWAPPER" }, async (name, opts) =>
    deploy(name, {
      ...opts,
      proxy: { owner: timelock, viaAdminContract: "ProxyAdmin", proxyContract: "TransparentUpgradeableProxy" },
      from: deployer,
      log: true,
    }),
  );

  await validateUpgrade(
    "ProtoStaker",
    { args: [exa, weth, pool, gauge, rewards], envKey: "PROTO_STAKER" },
    async (name, opts) =>
      deploy(name, {
        ...opts,
        proxy: {
          owner: timelock,
          viaAdminContract: "ProxyAdmin",
          proxyContract: "TransparentUpgradeableProxy",
          execute: { init: { methodName: "initialize", args: [] } },
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
