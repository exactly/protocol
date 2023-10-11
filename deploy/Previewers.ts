import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({
  network: {
    config: {
      finance: { periphery },
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
    { address: exa },
    { address: exaPool },
    { address: exaGauge },
    { address: priceFeedETH },
    { address: extraLending },
    { deployer },
  ] = await Promise.all([
    get("Auditor"),
    get("DebtManager"),
    get("EXA"),
    getOrNull("EXAPool").then((d) => d ?? { address: AddressZero }),
    getOrNull("EXAGauge").then((d) => d ?? { address: AddressZero }),
    getOrNull("PriceFeedETH").then((d) => d ?? { address: AddressZero }),
    getOrNull("ExtraLending").then((d) => d ?? { address: AddressZero }),
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

  if (periphery.extraReserve == null) return;
  await validateUpgrade(
    "VotePreviewer",
    { args: [exa, exaPool, exaGauge, extraLending, periphery.extraReserve], envKey: "VOTE_PREVIEWER" },
    async (name, opts) =>
      deploy(name, { ...opts, proxy: { proxyContract: "TransparentUpgradeableProxy" }, from: deployer, log: true }),
  );
};

func.tags = ["Previewers"];
func.dependencies = ["Auditor", "DebtManager", "UniswapV3"];

export default func;
