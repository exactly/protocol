import type { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async ({
  ethers: {
    utils: { parseUnits },
  },
  deployments: { deploy },
  getNamedAccounts,
}) => {
  const { deployer } = await getNamedAccounts();
  await deploy("InterestRateModel", {
    args: [
      parseUnits("0.0495"), // A parameter for the curve
      parseUnits("-0.025"), // B parameter for the curve
      parseUnits("1.1"), // target utilization rate
      parseUnits("0.0000002314814815"), // Penalty Rate per second. each day (86400) is 2%
    ],
    from: deployer,
    log: true,
  });
};

func.tags = ["InterestRateModel"];

export default func;
