import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor, TimelockController } from "../types";
import executeOrPropose from "./.utils/executeOrPropose";

const func: DeployFunction = async ({
  config: {
    finance: {
      liquidationIncentive: { liquidator: liquidatorIncentive, lenders: lendersIncentive },
    },
  },
  ethers: {
    utils: { parseUnits },
    getContract,
    getSigner,
  },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [timelockController, { address: oracleAddress }, { deployer }] = await Promise.all([
    getContract<TimelockController>("TimelockController"),
    get("ExactlyOracle"),
    getNamedAccounts(),
  ]);
  const liquidationIncentive = {
    liquidator: parseUnits(String(liquidatorIncentive)),
    lenders: parseUnits(String(lendersIncentive)),
  };

  await deploy("Auditor", {
    skipIfAlreadyDeployed: true,
    args: [oracleAddress, liquidationIncentive],
    from: deployer,
    log: true,
  });
  const auditor = await getContract<Auditor>("Auditor", await getSigner(deployer));

  if ((await auditor.oracle()) !== oracleAddress) {
    await executeOrPropose(deployer, timelockController, auditor, "setOracle", [oracleAddress]);
  }

  const currentLiquidationIncentive = await auditor.liquidationIncentive();
  if (
    !currentLiquidationIncentive.liquidator.eq(liquidationIncentive.liquidator) ||
    !currentLiquidationIncentive.lenders.eq(liquidationIncentive.lenders)
  ) {
    await executeOrPropose(deployer, timelockController, auditor, "setLiquidationIncentive", [liquidationIncentive]);
  }
};

func.tags = ["Auditor"];
func.dependencies = ["ExactlyOracle", "TimelockController"];

export default func;
