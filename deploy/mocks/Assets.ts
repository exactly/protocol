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
  for (const asset of config.assets) {
    const decimals = { USDC: 6, WBTC: 8 }[asset] ?? 18;
    await deploy(asset, {
      skipIfAlreadyDeployed: true,
      contract: asset === "WETH" ? "WETH" : "MockToken",
      ...(asset !== "WETH" && { args: [asset, asset, decimals, parseUnits("100000000000", decimals)] }),
      from: deployer,
      log: true,
    });
  }
};

func.tags = ["Assets"];

export default func;
