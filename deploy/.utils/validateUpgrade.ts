import hre from "hardhat";
import { env } from "process";
import { Manifest } from "@openzeppelin/upgrades-core";
import { validateImpl } from "@openzeppelin/hardhat-upgrades/dist/utils/validate-impl";
import { getDeployData } from "@openzeppelin/hardhat-upgrades/dist/utils/deploy-impl";
import { UnknownSignerError } from "hardhat-deploy/dist/src/errors";
import type { DeployResult } from "hardhat-deploy/types";
import type { ValidationError } from "@openzeppelin/upgrades-core/dist/validate/run";
import timelockPropose from "./timelockPropose";

const {
  ethers: { getContractAt, getContractFactory },
  deployments: { get, getOrNull },
  network: { provider },
} = hre;

export default async (name: string, opts?: DeployOptions, deploy?: DeployCallback) => {
  const deployData = await getDeployData(hre, await getContractFactory(opts?.contract ?? name), {
    constructorArgs: opts?.args,
    unsafeAllow: opts?.unsafeAllow,
  });
  await validateImpl(deployData, deployData.fullOpts, (await getOrNull(`${name}_Implementation`))?.address);

  if (!deploy) return;

  const { address, transactionHash: txHash, implementation } = await tryDeploy(deploy, name, opts);
  const { layout } = deployData;
  const manifest = await Manifest.forNetwork(provider);
  await manifest.lockedRun(async () => {
    const d = await manifest.read();

    if (!d.proxies.find((p) => p.address === address)) d.proxies.push({ kind: "transparent", address, txHash });

    if (implementation && !d.impls[implementation]) d.impls[implementation] = { address: implementation, layout };

    await manifest.write(d);
  });
};

async function tryDeploy(deploy: DeployCallback, name: string, opts?: DeployOptions) {
  try {
    return await deploy(
      name,
      opts?.envKey ? { skipIfAlreadyDeployed: !JSON.parse(env[`UPGRADE_${opts?.envKey}`] ?? "false"), ...opts } : opts,
    );
  } catch (error) {
    if (error instanceof UnknownSignerError) {
      const { to, contract } = error.data;
      if (!to || !contract) throw error;

      await timelockPropose(await getContractAt(contract.name, to), contract.method, contract.args);

      return {
        ...(await get(`${name}_Proxy`)),
        implementation: (await get(`${name}_Implementation`)).address,
      };
    }

    throw error;
  }
}

type DeployCallback = (
  name: string,
  opts?: DeployOptions,
) => Promise<Pick<DeployResult, "address" | "transactionHash" | "implementation">>;

interface DeployOptions {
  contract?: string;
  args?: unknown[];
  envKey?: string;
  unsafeAllow?: ValidationError["kind"][];
  skipIfAlreadyDeployed?: boolean;
}
