import { basename } from "path";
import { config, getChainId, network, tenderly } from "hardhat";
import type { Deployment } from "hardhat-deploy/types";

export default async (name: string, { address, metadata }: Deployment) => {
  if (!network.live) return;
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

  // eslint-disable-next-line deprecation/deprecation
  await tenderly.pushAPI(
    {
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
    },
    config.tenderly.project,
    config.tenderly.username,
  );
};
