import { deployments } from "hardhat";
import type { Contract, Signer } from "ethers";
import type { AccessControl } from "../../types";
import timelockPropose from "./timelockPropose";
import format from "./format";

export default async (contract: AccessControl, functionName: string, args?: readonly unknown[]) => {
  if (await contract.hasRole(await contract.DEFAULT_ADMIN_ROLE(), await (contract.runner! as Signer).getAddress())) {
    deployments.log("executing", `${await format(contract.target)}.${functionName}`, await format(args));
    await (await (contract as unknown as Contract)[functionName](...(args ?? []))).wait();
  } else {
    await timelockPropose(contract, functionName, args);
  }
};
