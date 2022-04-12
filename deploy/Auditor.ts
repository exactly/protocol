import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor, TimelockController } from "../types";
import executeOrPropose from "./.utils/executeOrPropose";

const func: DeployFunction = async ({
  config: {
    finance: { liquidationIncentive },
  },
  ethers: {
    utils: { parseUnits },
    getContract,
    getSigner,
  },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [timelockController, { deployer }] = await Promise.all([
    getContract<TimelockController>("TimelockController"),
    getNamedAccounts(),
  ]);

  await deploy("Auditor", {
    skipIfAlreadyDeployed: true,
    args: [(await get("ExactlyOracle")).address, parseUnits(String(liquidationIncentive))],
    from: deployer,
    log: true,
  });
  const auditor = await getContract<Auditor>("Auditor", await getSigner(deployer));
  await deploy("MaturityPositions", { args: [auditor.address], from: deployer, log: true });

  if (!(await auditor.liquidationIncentive()).eq(parseUnits(String(liquidationIncentive)))) {
    await executeOrPropose(deployer, timelockController, auditor, "setLiquidationIncentive", [
      parseUnits(String(liquidationIncentive)),
    ]);
  }
};

func.tags = ["Auditor"];
func.dependencies = ["ExactlyOracle"];

export default func;
