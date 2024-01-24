import { ethers } from "hardhat";
import type { BaseContract, Signer } from "ethers";
import type { TimelockController } from "../../../types";

const { ZeroHash, getContract } = ethers;

export default async (signer: Signer, contract: BaseContract, functionName: string, args?: readonly unknown[]) => {
  const timelock = await getContract<TimelockController>("TimelockController", signer);
  const calldata = contract.interface.encodeFunctionData(functionName, args);
  await timelock.schedule(contract.target, 0, calldata, ZeroHash, ZeroHash, 0);
  return timelock.execute(contract.target, 0, calldata, ZeroHash, ZeroHash);
};
