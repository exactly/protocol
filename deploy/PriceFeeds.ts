import { env } from "process";
import { BigNumber } from "ethers";
import { Interface } from "@ethersproject/abi";
import type { DeployFunction } from "hardhat-deploy/types";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({ network, deployments: { deploy, get, getOrNull }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();

  for (const [symbol, { priceFeed }] of Object.entries(network.config.finance.markets)) {
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

  const [exaPool, ethFeed, exa, weth] = await Promise.all([
    getOrNull("EXAPool"),
    get("PriceFeedWETH"),
    get("EXA"),
    get("WETH"),
  ]);
  if (!exaPool) return;

  await tenderlify(
    "PriceFeedPool",
    await deploy("PriceFeedEXA", {
      contract: "PriceFeedPool",
      args: [exaPool.address, ethFeed.address, BigInt(weth.address) > BigInt(exa.address)],
      skipIfAlreadyDeployed: !JSON.parse(env.DEPLOY_FEED_EXA ?? "false"),
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["PriceFeeds"];
func.dependencies = ["Assets"];

export default func;
