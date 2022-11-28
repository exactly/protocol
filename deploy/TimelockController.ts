import type { DeployFunction } from "hardhat-deploy/types";
import { TimelockController } from "../types";
import timelockPropose from "./.utils/timelockPropose";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({
  network: {
    config: { timelockDelay = 0 },
  },
  ethers: {
    constants: { AddressZero },
    getContract,
    getSigner,
  },
  deployments: { deploy },
  getNamedAccounts,
}) => {
  const { deployer, multisig } = await getNamedAccounts();
  await tenderlify(
    "TimelockController",
    await deploy("TimelockController", {
      skipIfAlreadyDeployed: true,
      args: [timelockDelay, [multisig, deployer], [multisig], AddressZero],
      from: deployer,
      log: true,
    }),
  );

  const timelock = await getContract<TimelockController>("TimelockController", await getSigner(deployer));
  if (!(await timelock.getMinDelay()).eq(timelockDelay)) {
    await timelockPropose(timelock, "updateDelay", [timelockDelay]);
  }
};

func.tags = ["TimelockController"];

export default func;
