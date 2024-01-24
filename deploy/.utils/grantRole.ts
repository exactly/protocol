import { deployments } from "hardhat";
import type { AccessControl } from "../../types";
import executeOrPropose from "./executeOrPropose";
import format from "./format";

const { log } = deployments;

export default async (contract: AccessControl, role: string, account: string) => {
  if (!(await contract.hasRole(role, account))) {
    log("granting role", `${await format(contract.target)}.${await format(role)}`, "to", await format(account));
    await executeOrPropose(contract, "grantRole", [role, account]);
  }
};
