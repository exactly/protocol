import { deployments } from "hardhat";
import type { AccessControl } from "../../types";
import format from "./format";

const { log } = deployments;

export default async (contract: AccessControl, role: string, account: string) => {
  if (await contract.hasRole(role, account)) {
    log("renouncing role", `${await format(contract.target)}.${await format(role)}`, "from", await format(account));
    await (await contract.renounceRole(role, account)).wait();
  }
};
