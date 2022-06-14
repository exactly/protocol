import { deployments } from "hardhat";
import type { IAccessControl } from "../../types";

export default async (contract: IAccessControl, role: string, account: string) => {
  if (!(await contract.hasRole(role, account))) {
    deployments.log("granting role", contract.address, role, account);
    await (await contract.grantRole(role, account)).wait();
  }
};
