import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({
  ethers: {
    constants: { AddressZero },
  },
  deployments: { getOrNull, save },
  network: { live },
}) => {
  if (!(await getOrNull("UniswapV3Factory")) && !live) {
    await save("UniswapV3Factory", { address: AddressZero, abi: [] });
  }
};

func.tags = ["UniswapV3Factory"];

export default func;
