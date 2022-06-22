import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor, TimelockController } from "../types";
import { MOCK_ORACLE } from "./mocks/MockOracle";
import executeOrPropose from "./.utils/executeOrPropose";

const oracleName = MOCK_ORACLE ? "MockOracle" : "ExactlyOracle";

const func: DeployFunction = async ({
  config: {
    finance: { liquidationIncentive: liquidationIncentiveFloat },
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
    get(oracleName),
    getNamedAccounts(),
  ]);
  const liquidationIncentive = parseUnits(String(liquidationIncentiveFloat));

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

  if (!(await auditor.liquidationIncentive()).eq(liquidationIncentive)) {
    await executeOrPropose(deployer, timelockController, auditor, "setLiquidationIncentive", [liquidationIncentive]);
  }
};

func.tags = ["Auditor"];
func.dependencies = [oracleName, "TimelockController"];

export default func;
