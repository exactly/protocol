import { UnknownSignerError } from "hardhat-deploy/dist/src/errors";
import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor, TimelockController } from "../types";
import executeOrPropose from "./.utils/executeOrPropose";
import timelockPropose from "./.utils/timelockPropose";

const func: DeployFunction = async ({
  config: {
    finance: {
      liquidationIncentive: { liquidator: liquidatorIncentive, lenders: lendersIncentive },
    },
  },
  ethers: {
    utils: { parseUnits },
    getContractAt,
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

  try {
    await deploy("Auditor", {
      proxy: {
        owner: timelockController.address,
        proxyContract: "ERC1967Proxy",
        proxyArgs: ["{implementation}", "{data}"],
        execute: {
          init: { methodName: "initialize", args: [timelockController.address, oracleAddress, liquidationIncentive] },
        },
      },
      from: deployer,
      log: true,
    });
  } catch (error) {
    if (error instanceof UnknownSignerError) {
      const { to, contract } = error.data;
      if (!to || !contract) throw error;

      await timelockPropose(timelockController, await getContractAt(contract.name, to), contract.method, contract.args);
    }
  }
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
