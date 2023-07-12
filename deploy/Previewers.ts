import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({
  network: {
    config: {
      finance: {
        periphery: { uniswapFees },
      },
    },
  },
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
  await validateUpgrade("Previewer", { args: [auditor, priceFeedETH], envKey: "PREVIEWER" }, async (name, opts) =>
    deploy(name, { ...opts, proxy: { proxyContract: "TransparentUpgradeableProxy" }, from: deployer, log: true }),
  );
  await validateUpgrade(
    "DebtPreviewer",
    { args: [debtManager, uniswapQuoter], envKey: "DEBT_PREVIEWER" },
    async (name, opts) =>
      deploy(name, {
        ...opts,
        proxy: {
          proxyContract: "TransparentUpgradeableProxy",
          execute: {
            init: {
              methodName: "initialize",
              args: [
                await Promise.all(uniswapFees.map(({ assets }) => assets.map(async (a) => (await get(a)).address))),
                uniswapFees.map(({ fee }) => fee * 1e4),
              ],
            },
          },
        },
        from: deployer,
        log: true,
      }),
  );
};

func.tags = ["Previewers"];
func.dependencies = ["Auditor", "DebtManager", "UniswapV3"];

export default func;
