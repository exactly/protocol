import type { AccessControl } from "../../types";

type AccessControlBase = Pick<AccessControl, "hasRole" | "grantRole" | "revokeRole" | "DEFAULT_ADMIN_ROLE">; // https://github.com/dethcrypto/TypeChain/issues/601

export default async (contract: AccessControlBase, from: string, to: string) => {
  const DEFAULT_ADMIN_ROLE = await contract.DEFAULT_ADMIN_ROLE();
  if (!(await contract.hasRole(DEFAULT_ADMIN_ROLE, to))) await contract.grantRole(DEFAULT_ADMIN_ROLE, to);
  if (await contract.hasRole(DEFAULT_ADMIN_ROLE, from)) await contract.revokeRole(DEFAULT_ADMIN_ROLE, from);
};
