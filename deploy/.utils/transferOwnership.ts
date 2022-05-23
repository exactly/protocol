import { deployments } from "hardhat";
import type { AccessControl } from "../../types";

export default async (contract: AccessControl, from: string, to: string) => {
  const DEFAULT_ADMIN_ROLE = await contract.DEFAULT_ADMIN_ROLE();
  if (!(await contract.hasRole(DEFAULT_ADMIN_ROLE, to))) {
    deployments.log("granting role", contract.address, DEFAULT_ADMIN_ROLE, to);
    await contract.grantRole(DEFAULT_ADMIN_ROLE, to);
  }
  if (await contract.hasRole(DEFAULT_ADMIN_ROLE, from)) {
    deployments.log("revoking role", contract.address, DEFAULT_ADMIN_ROLE, to);
    await contract.revokeRole(DEFAULT_ADMIN_ROLE, from);
  }
};
