import type { DeployFunction } from "hardhat-deploy/types";
import type { ProxyAdmin, TimelockController } from "../types";
import timelockPropose from "./.utils/timelockPropose";
import revokeRole from "./.utils/revokeRole";
import tenderlify from "./.utils/tenderlify";
import { keccak256, toUtf8Bytes } from "ethers";

const func: DeployFunction = async ({
  network: {
    config: { timelockDelay = 0 },
  },
  ethers: { ZeroAddress, getContract, getSigner },
  deployments: { deploy },
  getNamedAccounts,
}) => {
  const { deployer, multisig } = await getNamedAccounts();

  const { address: timelockAddress } = await tenderlify(
    "TimelockController",
    await deploy("TimelockController", {
      skipIfAlreadyDeployed: true,
      args: [timelockDelay, [multisig, deployer], [multisig], ZeroAddress],
      from: deployer,
      log: true,
    }),
  );

  await tenderlify(
    "ProxyAdmin",
    await deploy("ProxyAdmin", { skipIfAlreadyDeployed: true, from: deployer, log: true }),
  );

  const timelock = await getContract<TimelockController>("TimelockController", await getSigner(deployer));
  if ((await timelock.getMinDelay()) !== BigInt(timelockDelay)) {
    await timelockPropose(timelock, "updateDelay", [timelockDelay]);
  }
  await revokeRole(
    timelock,
    keccak256(toUtf8Bytes("CANCELLER_ROLE")),
    deployer,
    keccak256(toUtf8Bytes("TIMELOCK_ADMIN_ROLE")),
  );

  const proxyAdmin = await getContract<ProxyAdmin>("ProxyAdmin", await getSigner(deployer));
  if ((await proxyAdmin.owner()).toLowerCase() !== timelockAddress.toLowerCase()) {
    await (await proxyAdmin.transferOwnership(timelockAddress)).wait();
  }
};

func.tags = ["Governance"];

export default func;
