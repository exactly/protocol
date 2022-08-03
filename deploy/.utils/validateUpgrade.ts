import hre from "hardhat";
import { getDeployData } from "@openzeppelin/hardhat-upgrades/dist/utils/deploy-impl";
import { assertUpgradeSafe } from "@openzeppelin/upgrades-core";

const {
  ethers: { getContractFactory },
} = hre;

export default async (contractName: string, constructorArgs?: unknown[]) => {
  const { validations, version, fullOpts } = await getDeployData(hre, await getContractFactory(contractName), {
    constructorArgs,
  });

  assertUpgradeSafe(validations, version, fullOpts);
};
