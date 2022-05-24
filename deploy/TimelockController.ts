import type { DeployFunction } from "hardhat-deploy/types";
import { TimelockController } from "../types";
import timelockPropose from "./.utils/timelockPropose";

const func: DeployFunction = async ({
  network: {
    config: { timelockDelay = 0 },
  },
  ethers: { getContract, getSigner },
  deployments: { deploy },
  getNamedAccounts,
}) => {
  const { deployer, multisig } = await getNamedAccounts();
  await deploy("TimelockController", {
    skipIfAlreadyDeployed: true,
    args: [timelockDelay, [multisig, deployer], [multisig]],
    from: deployer,
    log: true,
  });

  const timelock = await getContract<TimelockController>("TimelockController", await getSigner(deployer));
  if (!(await timelock.getMinDelay()).eq(timelockDelay)) {
    await timelockPropose(timelock, timelock, "updateDelay", [timelockDelay]);
  }
};

func.tags = ["TimelockController"];

export default func;
