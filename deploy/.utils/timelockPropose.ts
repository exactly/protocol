import hre from "hardhat";
import type { Contract } from "ethers";
import type { TimelockController } from "../../types";
import multisigPropose from "./multisigPropose";

const {
  ethers: {
    constants: { HashZero },
  },
  deployments: { log },
} = hre;

export default async (
  timelock: TimelockController,
  contract: Contract,
  functionName: string,
  args?: readonly unknown[],
) => {
  const calldata = contract.interface.encodeFunctionData(functionName, args);

  if (!(await timelock.isOperation(await timelock.hashOperation(contract.address, 0, calldata, HashZero, HashZero)))) {
    log("timelock: proposing", contract.address, functionName, args);
    await (
      await timelock.schedule(contract.address, 0, calldata, HashZero, HashZero, await timelock.getMinDelay())
    ).wait();
  }

  await multisigPropose(hre, "deployer", timelock, "execute", [contract.address, 0, calldata, HashZero, HashZero]);
};
