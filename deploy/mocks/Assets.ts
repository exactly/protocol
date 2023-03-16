import { env } from "process";
import { ethers, network } from "hardhat";
import type { MarketConfig } from "hardhat/types/config";
import type { DeployFunction } from "hardhat-deploy/types";
import type { MockPriceFeed } from "../../types";

const {
  utils: { parseUnits, formatUnits },
  getContract,
  getSigner,
} = ethers;
const {
  config: { priceDecimals, markets },
  live,
} = network;

export const mockPrices = Object.fromEntries(
  Object.keys(markets)
    .filter((symbol) => live && env[`${symbol}_PRICE`])
    .map((symbol) => [symbol, parseUnits(env[`${symbol}_PRICE`] as string, priceDecimals)]),
);

const func: DeployFunction = async ({ deployments: { deploy, log }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  const signer = await getSigner(deployer);
  for (const [symbol, { priceFeed }] of [
    ...Object.entries(markets),
    ...[...new Set(Object.values(markets).flatMap((m) => m.rewards && Object.keys(m.rewards)))]
      .filter((asset) => asset && !markets[asset])
      .map((asset) => [asset, {}] as [string, MarketConfig]),
  ]) {
    const decimals = { USDC: 6, WBTC: 8 }[symbol] ?? 18;
    await deploy(symbol, {
      skipIfAlreadyDeployed: true,
      contract: symbol === "WETH" ? "WETH" : "MockERC20",
      ...(symbol !== "WETH" && { args: [symbol, symbol, decimals] }),
      from: deployer,
      log: true,
    });

    if (priceFeed === "double") {
      await deploy(`PriceFeed${symbol}Two`, {
        skipIfAlreadyDeployed: true,
        contract: "MockPriceFeed",
        args: [0, 1],
        from: deployer,
        log: true,
      });
    } else if (priceFeed) {
      await deploy(priceFeed.wrapper, {
        skipIfAlreadyDeployed: true,
        contract: "MockStETH",
        args: [parseUnits("1")],
        from: deployer,
        log: true,
      });
    }

    await deploy(`PriceFeed${symbol}${priceFeed ? (priceFeed === "double" ? "One" : "Main") : ""}`, {
      skipIfAlreadyDeployed: true,
      contract: "MockPriceFeed",
      args: [priceDecimals, parseUnits({ WBTC: "63000", WETH: "1000", OP: "3" }[symbol] ?? "1", priceDecimals)],
      from: deployer,
      log: true,
    });
    if (symbol in mockPrices) {
      const name = `MockPriceFeed${symbol}`;
      await deploy(name, {
        skipIfAlreadyDeployed: true,
        contract: "MockPriceFeed",
        args: [mockPrices[symbol]],
        from: deployer,
        log: true,
      });
      const mockPriceFeed = await getContract<MockPriceFeed>(name, signer);
      if (!mockPrices[symbol].eq(await mockPriceFeed.price())) {
        log("setting price", symbol, formatUnits(mockPrices[symbol], priceDecimals));
        await (await mockPriceFeed.setPrice(mockPrices[symbol])).wait();
      }
    }
  }
};

func.tags = ["Assets"];

export default func;
