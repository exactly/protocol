import type { IAccessControl } from "../../types";

export default async (contract: IAccessControl, role: string, account: string) => {
  if (!(await contract.hasRole(role, account))) {
    console.log("granting role", contract.address, role, account);
    await contract.grantRole(role, account);
  }
};
