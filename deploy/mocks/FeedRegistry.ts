import type { DeployFunction } from "hardhat-deploy/types";
import type { MockChainlinkFeedRegistry } from "../../types";
import { USD_ADDRESS, ETH_ADDRESS, BTC_ADDRESS } from "../ExactlyOracle";

const func: DeployFunction = async ({
  ethers: { getContract },
  network: { config },
  deployments: { get, deploy, log },
  getNamedAccounts,
}) => {
  const { deployer } = await getNamedAccounts();
  const { receipt } = await deploy("FeedRegistry", {
    skipIfAlreadyDeployed: true,
    contract: "MockChainlinkFeedRegistry",
    from: deployer,
    log: true,
  });
  if (receipt) {
    const feedRegistry = await getContract<MockChainlinkFeedRegistry>("FeedRegistry");
    for (const token of config.tokens) {
      const { address } = await get(token);
      const price = { WBTC: 63_000e8, WETH: 1_000e8 }[token] ?? 1e8;
      log("setting price", token, price);
      await feedRegistry.setPrice({ WBTC: BTC_ADDRESS, WETH: ETH_ADDRESS }[token] ?? address, USD_ADDRESS, price);
    }
  }
};

func.tags = ["FeedRegistry"];
func.dependencies = ["Tokens"];

export default func;
