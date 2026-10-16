import { env } from "process";
import type { DeployFunction } from "hardhat-deploy/types";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [{ address: morpho }, { deployer }] = await Promise.all([get("Morpho"), getNamedAccounts()]);

  await tenderlify(
    "FlashLoanAdapter",
    await deploy("FlashLoanAdapter", {
      args: [morpho],
      skipIfAlreadyDeployed: !JSON.parse(env[`DEPLOY_FLASH_LOAN`] ?? "false"),
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["FlashLoan"];
func.skip = async ({ network, deployments }) => !!network.config.sunset || !(await deployments.getOrNull("Morpho"));

export default func;
