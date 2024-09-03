import { ethers, deployments } from "hardhat";
import type { BaseContract, Signer } from "ethers";
import type { TimelockController } from "../../types";
import multisigPropose from "./multisigPropose";
import format from "./format";

const { ZeroHash, getContract } = ethers;
const { log } = deployments;

export default async (contract: BaseContract, functionName: string, args?: readonly unknown[], safe?: string) => {
  const timelock = await getContract<TimelockController>("TimelockController", contract.runner! as Signer);
  const calldata = contract.interface.encodeFunctionData(functionName, args);

  let predecessor = ZeroHash;
  let operation = await timelock.hashOperation(contract.target, 0, calldata, predecessor, ZeroHash);
  while ((await Promise.all([timelock.isOperation(operation), timelock.isOperationDone(operation)])).every(Boolean)) {
    predecessor = operation;
    operation = await timelock.hashOperation(contract.target, 0, calldata, predecessor, ZeroHash);
  }

  if (!(await timelock.isOperation(operation))) {
    log("timelock: proposing", `${await format(contract.target)}.${functionName}`, await format(args));
    await (
      await timelock.schedule(contract.target, 0, calldata, predecessor, ZeroHash, await timelock.getMinDelay())
    ).wait();
  }

  try {
    await multisigPropose("deployer", timelock, "execute", [contract.target, 0, calldata, predecessor, ZeroHash], safe);
  } catch (error) {
    if (error instanceof Error) log("multisig: error", error.message);
    log("timelock: executing", `${await format(contract.target)}.${functionName}`, await format(args));
    await (await timelock.execute(contract.target, 0, calldata, predecessor, ZeroHash)).wait();
  }
};
