import { basename } from "path";
import { getChainId, network, tenderly } from "hardhat";
import type { Deployment } from "hardhat-deploy/types";

export default async (name: string, deployment: Deployment) => {
  if (!network.live) return deployment;

  const { address, metadata } = deployment;
  if (!metadata) throw new Error("missing metadata");

  const {
    settings: { optimizer },
    compiler,
    sources,
  } = JSON.parse(metadata) as {
    compiler: { version: string };
    settings: { optimizer: { enabled: boolean; runs: number } };
    sources: { [key: string]: { content: string } };
  };

  const chainId = await getChainId();
  const version = compiler.version.slice(0, compiler.version.indexOf("+"));

  await tenderly.verifyAPI({
    contracts: Object.entries(sources).map(([sourcePath, { content: source }]) => {
      const contractName = basename(sourcePath, ".sol");
      return {
        contractName,
        source,
        sourcePath,
        networks: { ...(contractName === name && { [chainId]: { address } }) },
        compiler: { name: "solc", version },
      };
    }),
    config: { compiler_version: version, optimizations_used: optimizer.enabled, optimizations_count: optimizer.runs },
  });

  return deployment;
};
