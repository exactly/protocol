import type { DeployFunction } from "hardhat-deploy/types";
import type { MockedChainlinkFeedRegistry } from "../../types";
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
    contract: "MockedChainlinkFeedRegistry",
    from: deployer,
    log: true,
  });
  if (newlyDeployed) {
    const feedRegistry = await getContract<MockedChainlinkFeedRegistry>("FeedRegistry");
    for (const token of config.tokens) {
      const { address } = await get(token);
      await feedRegistry.setPrice(address, USD_ADDRESS, { WBTC: 63_000e8, WETH: 1_000e8 }[token] ?? 1e8);
    }
  }
};

func.tags = ["FeedRegistry"];
func.dependencies = ["Tokens"];

export default func;
