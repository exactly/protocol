import type { Contract } from "ethers";
import type { TimelockController } from "../../types";
import timelockPropose from "./timelockPropose";

export default async (
  address: string,
  timelock: TimelockController,
  contract: Contract,
  functionName: string,
  args?: readonly unknown[],
) => {
  if (await contract.hasRole(await contract.DEFAULT_ADMIN_ROLE(), address)) {
    console.log("executing", contract.address, functionName, args);
    await contract[functionName](...(args ?? []));
  } else {
    console.log("proposing", contract.address, functionName, args);
    await timelockPropose(timelock, contract.connect(address), functionName, args);
  }
};
