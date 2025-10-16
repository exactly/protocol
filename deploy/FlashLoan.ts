import { env } from "process";
import type { DeployFunction } from "hardhat-deploy/types";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [{ address: flashLoaner }, { address: timelock }, { deployer }] = await Promise.all([
    get("BalancerVault"),
    get("TimelockController"),
    getNamedAccounts(),
  ]);

  await tenderlify(
    "FlashLoanAdapter",
    await deploy("FlashLoanAdapter", {
      args: [flashLoaner, timelock],
      skipIfAlreadyDeployed: !JSON.parse(env[`DEPLOY_FLASH_LOAN`] ?? "false"),
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["FlashLoan"];
func.dependencies = ["Governance", "Balancer"];
func.skip = async ({ network }) => !!network.config.sunset;

export default func;
