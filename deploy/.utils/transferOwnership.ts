import type { AccessControl } from "../../types";
import renounceRole from "./renounceRole";
import grantRole from "./grantRole";
import { ZeroHash } from "ethers";

export default async (contract: AccessControl, from: string, to: string, ownershipRole = ZeroHash) => {
  await grantRole(contract, ownershipRole, to);
  await renounceRole(contract, ownershipRole, from);
};
