import { deployments } from "hardhat";
import { ZeroHash, type Contract, type Signer } from "ethers";
import type { AccessControl } from "../../types";
import timelockPropose from "./timelockPropose";
import format from "./format";

export default async (
  contract: AccessControl,
  functionName: string,
  args?: readonly unknown[],
  adminRole = ZeroHash,
  safe?: string,
) => {
  if (await contract.hasRole(adminRole, await (contract.runner! as Signer).getAddress())) {
    deployments.log("executing", `${await format(contract.target)}.${functionName}`, await format(args));
    await (await (contract as unknown as Contract)[functionName](...(args ?? []))).wait();
  } else {
    await timelockPropose(contract, functionName, args, safe);
  }
};
