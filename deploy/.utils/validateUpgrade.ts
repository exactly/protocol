import hre from "hardhat";
import { getDeployData } from "@openzeppelin/hardhat-upgrades/dist/utils/deploy-impl";
import {
  assertStorageUpgradeSafe,
  assertUpgradeSafe,
  getStorageLayoutForAddress,
  Manifest,
} from "@openzeppelin/upgrades-core";
import type { DeployResult } from "hardhat-deploy/types";

const {
  ethers: { getContractFactory },
  deployments: { getOrNull },
  network: { provider },
} = hre;

export default async (
  contractName: string,
  constructorArgs?: unknown[],
  deploy?: (
    name: string,
    args?: unknown[],
  ) => Promise<Pick<DeployResult, "address" | "transactionHash" | "implementation">>,
) => {
  const { validations, version, fullOpts, layout } = await getDeployData(hre, await getContractFactory(contractName), {
    constructorArgs,
  });

  assertUpgradeSafe(validations, version, fullOpts);

  const currentImpl = await getOrNull(`${contractName}_Implementation`);
  if (currentImpl) {
    const manifest = await Manifest.forNetwork(provider);
    const currentLayout = await getStorageLayoutForAddress(manifest, validations, currentImpl.address);
    assertStorageUpgradeSafe(currentLayout, layout, fullOpts);
  }

  if (deploy) {
    const { address, transactionHash: txHash, implementation } = await deploy(contractName, constructorArgs);
    const manifest = await Manifest.forNetwork(provider);
    await manifest.lockedRun(async () => {
      const d = await manifest.read();

      if (!d.proxies.find((p) => p.address === address)) d.proxies.push({ kind: "uups", address, txHash });

      if (implementation && !d.impls[implementation]) d.impls[implementation] = { address: implementation, layout };

      await manifest.write(d);
    });
  }
};
