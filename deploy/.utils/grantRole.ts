import type { IAccessControl } from "../../types";

export default async (contract: IAccessControl, role: string, account: string) => {
  if (!(await contract.hasRole(role, account))) await contract.grantRole(role, account);
};
