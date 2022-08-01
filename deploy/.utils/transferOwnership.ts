import type { AccessControl } from "../../types";
import revokeRole from "./revokeRole";
import grantRole from "./grantRole";

export default async (contract: AccessControl, from: string, to: string, ownershipRole?: string) => {
  ownershipRole ??= await contract.DEFAULT_ADMIN_ROLE();
  await grantRole(contract, ownershipRole, to);
  await revokeRole(contract, ownershipRole, from);
};
