import { deployments } from "hardhat";
import type { AccessControl } from "../../types";
import executeOrPropose from "./executeOrPropose";
import format from "./format";

const { log } = deployments;

export default async (contract: AccessControl, role: string, account: string, adminRole?: string) => {
  if (await contract.hasRole(role, account)) {
    log("revoking role", `${await format(contract.target)}.${await format(role)}`, "from", await format(account));
    await executeOrPropose(contract, "revokeRole", [role, account], adminRole);
  }
};
