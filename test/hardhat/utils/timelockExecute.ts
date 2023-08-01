import { ethers } from "hardhat";
import type { Contract, Signer } from "ethers";
import type { TimelockController } from "../../../types";

const {
  constants: { HashZero },
  getContract,
} = ethers;

export default async (signer: Signer, contract: Contract, functionName: string, args?: readonly unknown[]) => {
  const timelock = await getContract<TimelockController>("TimelockController", signer);
  const calldata = contract.interface.encodeFunctionData(functionName, args);
  await timelock.schedule(contract.address, 0, calldata, HashZero, HashZero, 0);
  return timelock.execute(contract.address, 0, calldata, HashZero, HashZero);
};
