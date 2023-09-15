import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({
  ethers: {
    constants: { AddressZero },
  },
  deployments: { deploy, get, getOrNull },
  getNamedAccounts,
}) => {
  const [{ address: auditor }, { address: debtManager }, { address: priceFeedETH }, { deployer }] = await Promise.all([
    get("Auditor"),
    get("DebtManager"),
    getOrNull("PriceFeedETH").then((d) => d ?? { address: AddressZero }),
    getNamedAccounts(),
  ]);
  await validateUpgrade("Previewer", { args: [auditor, priceFeedETH], envKey: "PREVIEWER" }, async (name, opts) =>
    deploy(name, { ...opts, proxy: { proxyContract: "TransparentUpgradeableProxy" }, from: deployer, log: true }),
  );
  await validateUpgrade("DebtPreviewer", { args: [debtManager], envKey: "DEBT_PREVIEWER" }, async (name, opts) =>
    deploy(name, {
      ...opts,
      proxy: { proxyContract: "TransparentUpgradeableProxy" },
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["Previewers"];
func.dependencies = ["Auditor", "DebtManager", "UniswapV3"];

export default func;
