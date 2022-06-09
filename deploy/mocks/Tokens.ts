import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({ network: { config }, deployments: { deploy }, getNamedAccounts }) => {
  const { deployer } = await getNamedAccounts();
  for (const symbol of config.tokens) {
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
  }
};

func.tags = ["Tokens"];

export default func;
