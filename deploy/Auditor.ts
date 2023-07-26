import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor } from "../types";
import executeOrPropose from "./.utils/executeOrPropose";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({
  network: {
    config: {
      priceDecimals,
      finance: {
        liquidationIncentive: { liquidator: liquidatorIncentive, lenders: lendersIncentive },
      },
    },
  },
  ethers: {
    utils: { parseUnits },
    getContract,
    getSigner,
  },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [{ address: timelockAddress }, { deployer }] = await Promise.all([
    get("TimelockController"),
    getNamedAccounts(),
  ]);
  const liquidationIncentive = {
    liquidator: parseUnits(String(liquidatorIncentive)),
    lenders: parseUnits(String(lendersIncentive)),
  };

  await validateUpgrade("Auditor", { args: [priceDecimals], envKey: "AUDITOR" }, async (name, opts) =>
    deploy(name, {
      ...opts,
      proxy: {
        owner: timelockAddress,
        viaAdminContract: "ProxyAdmin",
        proxyContract: "TransparentUpgradeableProxy",
        execute: {
          init: { methodName: "initialize", args: [liquidationIncentive] },
        },
      },
      from: deployer,
      log: true,
    }),
  );
  const auditor = await getContract<Auditor>("Auditor", await getSigner(deployer));

  const currentLiquidationIncentive = await auditor.liquidationIncentive();
  if (
    !currentLiquidationIncentive.liquidator.eq(liquidationIncentive.liquidator) ||
    !currentLiquidationIncentive.lenders.eq(liquidationIncentive.lenders)
  ) {
    await executeOrPropose(auditor, "setLiquidationIncentive", [liquidationIncentive]);
  }
};

func.tags = ["Auditor"];
func.dependencies = ["Governance"];

export default func;
