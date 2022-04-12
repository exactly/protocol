import type { DeployFunction } from "hardhat-deploy/types";
import type { MockChainlinkFeedRegistry } from "../../types";
import { USD_ADDRESS } from "../ExactlyOracle";

const func: DeployFunction = async ({
  ethers: { getContract },
  network: { config },
  deployments: { get, deploy },
  getNamedAccounts,
}) => {
  const { deployer } = await getNamedAccounts();
  const { newlyDeployed } = await deploy("FeedRegistry", {
    skipIfAlreadyDeployed: true,
    contract: "MockChainlinkFeedRegistry",
    from: deployer,
    log: true,
  });
  if (newlyDeployed) {
    const feedRegistry = await getContract<MockChainlinkFeedRegistry>("FeedRegistry");
    for (const asset of config.assets) {
      const { address } = await get(asset);
      await feedRegistry.setPrice(address, USD_ADDRESS, { WBTC: 63_000e8, WETH: 1_000e8 }[asset] ?? 1e8);
    }
  }
};

func.tags = ["FeedRegistry"];
func.dependencies = ["Assets"];

export default func;
