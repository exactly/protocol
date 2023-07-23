import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({
  ethers: {
    utils: { hexZeroPad },
  },
  deployments: { getOrNull, save },
  network: { live },
}) => {
  if (!(await getOrNull("SablierV2LockupLinear")) && !live) {
    await save("SablierV2LockupLinear", { address: hexZeroPad("0x1", 20), abi: [] });
  }
};

func.tags = ["Sablier"];

export default func;
