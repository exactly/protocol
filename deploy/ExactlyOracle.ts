import type { DeployFunction } from "hardhat-deploy/types";
import type { ExactlyOracle, TimelockController } from "../types";
import timelockPropose from "./.utils/timelockPropose";

export const USD_ADDRESS = "0x0000000000000000000000000000000000000348";

const func: DeployFunction = async ({
  ethers: {
    constants: { AddressZero },
    getContract,
  },
  network: { config },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const addresses = (assets: string[]) => Promise.all(assets.map(async (asset) => (await get(asset)).address));

  const { deployer } = await getNamedAccounts();
  await deploy("ExactlyOracle", {
    skipIfAlreadyDeployed: true,
    args: [(await get("FeedRegistry")).address, config.assets, await addresses(config.assets), USD_ADDRESS, 86_400],
    from: deployer,
    log: true,
  });
  const oracle = await getContract<ExactlyOracle>("ExactlyOracle");
  const missingAssets = config.assets.filter(async (asset) => (await oracle.assetsSources(asset)) === AddressZero);
  if (missingAssets.length) {
    const timelock = await getContract<TimelockController>("TimelockController", deployer);
    await timelockPropose(timelock, oracle, "setAssetSources", [missingAssets, await addresses(missingAssets)]);
  }
};

func.tags = ["ExactlyOracle"];
func.dependencies = ["FeedRegistry", "Assets", "TimelockController"];

export default func;
