import type { DeployFunction } from "hardhat-deploy/types";
import type { ExactlyOracle, TimelockController } from "../types";
import timelockPropose from "./.utils/timelockPropose";

export const USD_ADDRESS = "0x0000000000000000000000000000000000000348";

const func: DeployFunction = async ({
  ethers: {
    constants: { AddressZero },
    getContract,
  },
  network: { config },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const addresses = (tokens: string[]) => Promise.all(tokens.map(async (token) => (await get(token)).address));

  const { deployer } = await getNamedAccounts();
  await deploy("ExactlyOracle", {
    skipIfAlreadyDeployed: true,
    args: [(await get("FeedRegistry")).address, config.tokens, await addresses(config.tokens), USD_ADDRESS, 86_400],
    from: deployer,
    log: true,
  });
  const oracle = await getContract<ExactlyOracle>("ExactlyOracle");
  const missingTokens = config.tokens.filter(async (token) => (await oracle.assetsSources(token)) === AddressZero);
  if (missingTokens.length) {
    const timelock = await getContract<TimelockController>("TimelockController", deployer);
    await timelockPropose(timelock, oracle, "setAssetSources", [missingTokens, await addresses(missingTokens)]);
  }
};

func.tags = ["ExactlyOracle"];
func.dependencies = ["FeedRegistry", "Tokens", "TimelockController"];

export default func;
