import type { DeployFunction } from "hardhat-deploy/types";
import Leverager from "../Leverager";

const func: DeployFunction = async ({
  ethers: {
    constants: { AddressZero },
  },
  deployments: { getOrNull, save },
  network: { live },
}) => {
  if (!(await getOrNull("BalancerVault")) && !live) await save("BalancerVault", { address: AddressZero, abi: [] });
};

func.tags = ["BalancerVault"];
func.skip = Leverager.skip;

export default func;
