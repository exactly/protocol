import { deployments } from "hardhat";
import type { Contract } from "ethers";
import timelockPropose from "./timelockPropose";
import format from "./format";

export default async (address: string, contract: Contract, functionName: string, args?: readonly unknown[]) => {
  if (await contract.hasRole(await contract.DEFAULT_ADMIN_ROLE(), address)) {
    deployments.log("executing", `${await format(contract.address)}.${functionName}`, await format(args));
    await (await contract[functionName](...(args ?? []))).wait();
  } else {
    await timelockPropose(contract.connect(address), functionName, args);
  }
};
