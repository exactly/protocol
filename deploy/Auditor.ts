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
      verified,
    },
  },
  ethers: { parseUnits, getContract, getSigner },
  deployments: { deploy, get, getOrNull },
  getNamedAccounts,
}) => {
  const [{ address: timelockAddress }, firewall, { deployer }] = await Promise.all([
    get("TimelockController"),
    getOrNull("Firewall"),
    getNamedAccounts(),
  ]);
  const liquidationIncentive = {
    liquidator: parseUnits(String(liquidatorIncentive)),
    lenders: parseUnits(String(lendersIncentive)),
  };

  await validateUpgrade("Auditor", { args: [priceDecimals], envKey: "AUDITOR" }, async (name, opts) =>
    deploy(name, {
      ...opts,
      contract: verified ? "VerifiedAuditor" : "Auditor",
      proxy: {
        owner: timelockAddress,
        viaAdminContract: { name: "ProxyAdmin" },
        proxyContract: "TransparentUpgradeableProxy",
        execute: {
          init: {
            methodName: verified ? "initializeVerified" : "initialize",
            args: [liquidationIncentive, ...(verified ? [firewall!.address] : [])],
          },
        },
      },
      from: deployer,
      log: true,
    }),
  );
  const auditor = await getContract<Auditor>("Auditor", await getSigner(deployer));

  const currentLiquidationIncentive = await auditor.liquidationIncentive();
  if (
    currentLiquidationIncentive.liquidator !== liquidationIncentive.liquidator ||
    currentLiquidationIncentive.lenders !== liquidationIncentive.lenders
  ) {
    await executeOrPropose(auditor, "setLiquidationIncentive", [liquidationIncentive]);
  }
};

func.tags = ["Auditor"];
func.dependencies = ["Governance", "Firewall"];

export default func;
