import { deployments } from "hardhat";
import type { IAccessControl } from "../../types";
import executeOrPropose from "./executeOrPropose";
import format from "./format";

const { log } = deployments;

export default async (contract: IAccessControl, role: string, account: string) => {
  if (await contract.hasRole(role, account)) {
    log("revoking role", `${await format(contract.address)}.${await format(role)}`, "from", await format(account));
    await executeOrPropose(contract, "revokeRole", [role, account]);
  }
};
