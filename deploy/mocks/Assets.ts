import { env } from "process";
import { ethers, network, config } from "hardhat";
import type { DeployFunction } from "hardhat-deploy/types";
import type { MockPriceFeed } from "../../types";

const {
  utils: { parseUnits, formatUnits },
  getContract,
  getSigner,
} = ethers;

export const mockPrices = Object.fromEntries(
  config.finance.assets
    .filter((symbol) => network.live && env[`${symbol}_PRICE`])
    .map((symbol) => [symbol, parseUnits(env[`${symbol}_PRICE`] as string, 8)]),
);

const func: DeployFunction = async ({ config: { finance }, deployments: { deploy, log }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  const signer = await getSigner(deployer);
  for (const symbol of finance.assets) {
    const decimals = { USDC: 6, WBTC: 8 }[symbol] ?? 18;
    await deploy(symbol, {
      skipIfAlreadyDeployed: true,
      contract: symbol === "WETH" ? "WETH" : "MockERC20",
      ...(symbol !== "WETH" && { args: [symbol, symbol, decimals] }),
      from: deployer,
      log: true,
    });
    await deploy(`PriceFeed${symbol}`, {
      skipIfAlreadyDeployed: true,
      contract: "MockPriceFeed",
      args: [{ WBTC: 63_000e8, WETH: 1_000e8 }[symbol] ?? 1e8],
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
      const priceFeed = await getContract<MockPriceFeed>(name, signer);
      if (!mockPrices[symbol].eq(await priceFeed.price())) {
        log("setting price", symbol, formatUnits(mockPrices[symbol], 8));
        await (await priceFeed.setPrice(mockPrices[symbol])).wait();
      }
    }
  }
};

func.tags = ["Assets"];

export default func;
