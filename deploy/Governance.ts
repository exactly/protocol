import type { DeployFunction } from "hardhat-deploy/types";
import type { ProxyAdmin, TimelockController } from "../types";
import timelockPropose from "./.utils/timelockPropose";
import revokeRole from "./.utils/revokeRole";
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

  await tenderlify(
    "ProxyAdmin",
    await deploy("ProxyAdmin", { skipIfAlreadyDeployed: true, from: deployer, log: true }),
  );

  const timelock = await getContract<TimelockController>("TimelockController", await getSigner(deployer));
  if (!(await timelock.getMinDelay()).eq(timelockDelay)) {
    await timelockPropose(timelock, "updateDelay", [timelockDelay]);
  }
  await revokeRole(timelock, await timelock.CANCELLER_ROLE(), deployer);

  const proxyAdmin = await getContract<ProxyAdmin>("ProxyAdmin", await getSigner(deployer));
  if ((await proxyAdmin.owner()).toLowerCase() !== timelock.address.toLowerCase()) {
    await (await proxyAdmin.transferOwnership(timelock.address)).wait();
  }
};

func.tags = ["Governance"];

export default func;
