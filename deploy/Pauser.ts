import { env } from "process";
import type { DeployFunction } from "hardhat-deploy/types";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [{ address: auditor }, { deployer, hypernative }] = await Promise.all([get("Auditor"), getNamedAccounts()]);

  await tenderlify(
    "Pauser",
    await deploy("Pauser", {
      args: [auditor, hypernative],
      skipIfAlreadyDeployed: !JSON.parse(env[`DEPLOY_PAUSER`] ?? "false"),
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["Pauser"];
func.dependencies = ["Auditor"];
func.skip = async ({ getNamedAccounts }) => !(await getNamedAccounts()).hypernative;

export default func;
