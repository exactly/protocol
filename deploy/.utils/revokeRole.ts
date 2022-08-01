import { deployments } from "hardhat";
import type { IAccessControl } from "../../types";

export default async (contract: IAccessControl, role: string, account: string) => {
  if (await contract.hasRole(role, account)) {
    deployments.log("revoking role", contract.address, role, account);
    await (await contract.revokeRole(role, account)).wait();
  }
};
