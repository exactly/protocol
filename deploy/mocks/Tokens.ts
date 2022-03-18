import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({
  ethers: {
    utils: { parseUnits },
  },
  network: { config },
  deployments: { deploy },
  getNamedAccounts,
}) => {
  const { deployer } = await getNamedAccounts();
  for (const token of config.tokens) {
    const decimals = { USDC: 6, WBTC: 8 }[token] ?? 18;
    await deploy(token, {
      skipIfAlreadyDeployed: true,
      contract: token === "WETH" ? "WETH" : "MockToken",
      ...(token !== "WETH" && { args: [token, token, decimals, parseUnits("100000000000", decimals)] }),
      from: deployer,
      log: true,
    });
  }
};

func.tags = ["Tokens"];

export default func;
