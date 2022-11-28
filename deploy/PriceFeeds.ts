import { env } from "process";
import { BigNumber } from "ethers";
import { Interface } from "@ethersproject/abi";
import type { DeployFunction } from "hardhat-deploy/types";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({ network, deployments: { deploy, get }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();

  for (const [symbol, { priceFeed }] of Object.entries(network.config.markets)) {
    if (!priceFeed) continue;

    const skipIfAlreadyDeployed = !JSON.parse(env[`DEPLOY_FEED_${symbol}`] ?? "false");

    if (priceFeed === "double") {
      await tenderlify(
        "PriceFeedDouble",
        await deploy(`PriceFeed${symbol}`, {
          skipIfAlreadyDeployed,
          contract: "PriceFeedDouble",
          args: [(await get(`PriceFeed${symbol}One`)).address, (await get(`PriceFeed${symbol}Two`)).address],
          from: deployer,
          log: true,
        }),
      );
    } else if (priceFeed.wrapper) {
      const { address, abi } = await get(priceFeed.wrapper);
      await tenderlify(
        "PriceFeedWrapper",
        await deploy(`PriceFeed${symbol}`, {
          skipIfAlreadyDeployed,
          contract: "PriceFeedWrapper",
          args: [
            (await get(`PriceFeed${symbol}Main`)).address,
            address,
            new Interface(abi).getSighash(priceFeed.fn),
            BigNumber.from(priceFeed.baseUnit),
          ],
          from: deployer,
          log: true,
        }),
      );
    }
  }
};

func.tags = ["PriceFeeds"];
func.dependencies = ["Assets"];

export default func;
