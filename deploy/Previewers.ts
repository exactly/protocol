import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade, { type DeployCallback } from "./.utils/validateUpgrade";

const func: DeployFunction = async ({
  ethers: {
    constants: { AddressZero },
  },
  deployments: { deploy, get, getOrNull },
  getNamedAccounts,
}) => {
  const [
    { address: auditor },
    { address: debtManager },
    { address: uniswapQuoter },
    { address: priceFeedETH },
    { deployer },
  ] = await Promise.all([
    get("Auditor"),
    get("DebtManager"),
    get("UniswapV3Quoter"),
    getOrNull("PriceFeedETH").then((d) => d ?? { address: AddressZero }),
    getNamedAccounts(),
  ]);
  const callback: DeployCallback = async (name, opts) =>
    deploy(name, { ...opts, proxy: { proxyContract: "TransparentUpgradeableProxy" }, from: deployer, log: true });
  await validateUpgrade("Previewer", { args: [auditor, priceFeedETH], envKey: "PREVIEWER" }, callback);
  await validateUpgrade("DebtPreviewer", { args: [debtManager, uniswapQuoter], envKey: "DEBT_PREVIEWER" }, callback);
};

func.tags = ["Previewers"];
func.dependencies = ["Auditor", "DebtManager", "UniswapV3"];

export default func;
