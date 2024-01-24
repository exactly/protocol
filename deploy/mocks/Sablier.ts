import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({
  ethers: { zeroPadBytes },
  deployments: { getOrNull, save },
  network: { live },
}) => {
  if (!(await getOrNull("SablierV2LockupLinear")) && !live) {
    await save("SablierV2LockupLinear", { address: zeroPadBytes("0x01", 20), abi: [] });
  }
};

func.tags = ["Sablier"];

export default func;
