import hre from "hardhat";
import { Manifest } from "@openzeppelin/upgrades-core";
import { validateImpl } from "@openzeppelin/hardhat-upgrades/dist/utils/validate-impl";
import { getDeployData } from "@openzeppelin/hardhat-upgrades/dist/utils/deploy-impl";
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
  const deployData = await getDeployData(hre, await getContractFactory(contractName), { constructorArgs });
  await validateImpl(deployData, {}, (await getOrNull(`${contractName}_Implementation`))?.address);

  if (deploy) {
    const { address, transactionHash: txHash, implementation } = await deploy(contractName, constructorArgs);
    const { layout } = deployData;
    const manifest = await Manifest.forNetwork(provider);
    await manifest.lockedRun(async () => {
      const d = await manifest.read();

      if (!d.proxies.find((p) => p.address === address)) d.proxies.push({ kind: "uups", address, txHash });

      if (implementation && !d.impls[implementation]) d.impls[implementation] = { address: implementation, layout };

      await manifest.write(d);
    });
  }
};
