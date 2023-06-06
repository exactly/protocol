import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({
  ethers: {
    constants: { AddressZero },
  },
  deployments: { getOrNull, save },
  network: { live },
}) => {
  if (!(await getOrNull("Permit2")) && !live) await save("Permit2", { address: AddressZero, abi: [] });
};

func.tags = ["Permit2"];

export default func;
