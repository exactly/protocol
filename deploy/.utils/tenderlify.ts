import { basename } from "path";
import { config as hardhatConfig, getChainId, network, tenderly } from "hardhat";
import type { Deployment } from "hardhat-deploy/types";

export default async (name: string, deployment: Deployment) => {
  if (!network.live) return deployment;

  const { address, metadata } = deployment;
  if (!metadata) throw new Error("missing metadata");

  const {
    settings: { optimizer, debug },
    compiler,
    sources,
  } = JSON.parse(metadata) as {
    compiler: { version: string };
    settings: { optimizer: { enabled: boolean; runs: number }; debug?: { revertStrings?: string } };
    sources: { [key: string]: { content: string } };
  };

  const chainId = await getChainId();
  const version = compiler.version.slice(0, compiler.version.indexOf("+"));
  const contracts = Object.entries(sources).map(([sourcePath, { content: source }]) => {
    const contractName = basename(sourcePath, ".sol");
    return {
      contractName,
      source,
      sourcePath,
      networks: { ...(contractName === name && { [chainId]: { address } }) },
      compiler: { name: "solc", version },
    };
  });
  const config = {
    compiler_version: version,
    optimizations_used: optimizer.enabled,
    optimizations_count: optimizer.runs,
    debug,
  };
  await Promise.all([
    tenderly.verifyAPI({ contracts, config }),
    // eslint-disable-next-line deprecation/deprecation
    tenderly.pushAPI({ contracts, config }, hardhatConfig.tenderly.project, hardhatConfig.tenderly.username),
  ]);

  return deployment;
};
