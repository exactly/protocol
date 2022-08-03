import { deployments } from "hardhat";
import type { IAccessControl } from "../../types";
import format from "./format";

const { log } = deployments;

export default async (contract: IAccessControl, role: string, account: string) => {
  if (!(await contract.hasRole(role, account))) {
    log("granting role", `${await format(contract.address)}.${await format(role)}`, "to", await format(account));
    await (await contract.grantRole(role, account)).wait();
  }
};
