import { ethers } from "hardhat";
import type { Contract, Signer } from "ethers";
import type { TimelockController } from "../../types";

const {
  constants: { HashZero },
  getContract,
  provider,
} = ethers;

export default async (signer: Signer, contract: Contract, functionName: string, args?: readonly unknown[]) => {
  const timelock = await getContract<TimelockController>("TimelockController", signer);
  const calldata = contract.interface.encodeFunctionData(functionName, args);
  await timelock.schedule(contract.address, 0, calldata, HashZero, HashZero, 60);
  await provider.send("evm_increaseTime", [60]);
  await timelock.execute(contract.address, 0, calldata, HashZero, HashZero);
};
