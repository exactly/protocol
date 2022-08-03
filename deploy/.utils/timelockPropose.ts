import hre from "hardhat";
import type { Contract } from "ethers";
import type { TimelockController } from "../../types";
import multisigPropose from "./multisigPropose";
import format from "./format";

const {
  ethers: {
    constants: { HashZero },
  },
  deployments: { log },
  network,
} = hre;

export default async (
  timelock: TimelockController,
  contract: Contract,
  functionName: string,
  args?: readonly unknown[],
) => {
  const calldata = contract.interface.encodeFunctionData(functionName, args);

  let predecessor = HashZero;
  let operation = await timelock.hashOperation(contract.address, 0, calldata, predecessor, HashZero);
  while ((await Promise.all([timelock.isOperation(operation), timelock.isOperationDone(operation)])).every(Boolean)) {
    predecessor = operation;
    operation = await timelock.hashOperation(contract.address, 0, calldata, predecessor, HashZero);
  }

  if (!(await timelock.isOperation(operation))) {
    log("timelock: proposing", `${await format(contract.address)}.${functionName}`, await format(args));
    await (
      await timelock.schedule(contract.address, 0, calldata, predecessor, HashZero, await timelock.getMinDelay())
    ).wait();
  }

  if (network.config.gnosisSafeTxService) {
    await multisigPropose(hre, "deployer", timelock, "execute", [contract.address, 0, calldata, predecessor, HashZero]);
  } else {
    log("timelock: executing", `${await format(contract.address)}.${functionName}`, await format(args));
    await (await timelock.execute(contract.address, 0, calldata, predecessor, HashZero)).wait();
  }
};
