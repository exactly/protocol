import type { IAccessControl } from "../../types";

type IAccessControlBase = Pick<IAccessControl, "hasRole" | "grantRole">; // https://github.com/dethcrypto/TypeChain/issues/601

export default async (contract: IAccessControlBase, role: string, account: string) => {
  if (!(await contract.hasRole(role, account))) await contract.grantRole(role, account);
};
