import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({
  ethers: {
    constants: { AddressZero },
  },
  deployments: { getOrNull, save },
  network: { live },
}) => {
  if (live) return;
  if (!(await getOrNull("UniswapV3Factory"))) await save("UniswapV3Factory", { address: AddressZero, abi: [] });
  if (!(await getOrNull("UniswapV3Quoter"))) await save("UniswapV3Quoter", { address: AddressZero, abi: [] });
};

func.tags = ["UniswapV3"];

export default func;
