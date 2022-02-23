import { constants } from "ethers";
import type { Contract } from "ethers";
import type { TimelockController } from "../../types";

const { HashZero } = constants;

export default async (
  timelock: TimelockController,
  contract: Contract,
  functionName: string,
  args?: readonly unknown[],
) => {
  const calldata = contract.interface.encodeFunctionData(functionName, args);
  if (!(await timelock.isOperation(await timelock.hashOperation(contract.address, 0, calldata, HashZero, HashZero)))) {
    await timelock.schedule(contract.address, 0, calldata, HashZero, HashZero, await timelock.getMinDelay());
  }
};
