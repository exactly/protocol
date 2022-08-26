import type { DeployFunction } from "hardhat-deploy/types";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({
  config: {
    finance: {
      interestRateModel: { fixedCurve, floatingCurve },
    },
  },
  ethers: {
    utils: { parseUnits },
  },
  deployments: { deploy },
  getNamedAccounts,
}) => {
  const { deployer } = await getNamedAccounts();
  await tenderlify(
    "InterestRateModel",
    await deploy("InterestRateModel", {
      args: [
        parseUnits(String(fixedCurve.a)),
        parseUnits(String(fixedCurve.b)),
        parseUnits(String(fixedCurve.maxUtilization)),
        parseUnits(String(floatingCurve.a)),
        parseUnits(String(floatingCurve.b)),
        parseUnits(String(floatingCurve.maxUtilization)),
      ],
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["InterestRateModel"];

export default func;
