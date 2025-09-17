import { env } from "process";
import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({
  network: {
    config: {
      finance: { periphery },
    },
  },
  ethers: { ZeroAddress },
  deployments: { deploy, get, getOrNull },
  getNamedAccounts,
}) => {
  const [
    { address: auditor },
    { address: debtManager },
    { address: exa },
    { address: exaPool },
    { address: exaGauge },
    { address: beefyEXA },
    { address: beefyEXABoost },
    { address: priceFeedETH },
    { address: extraLending },
    { deployer },
  ] = await Promise.all([
    get("Auditor"),
    get("DebtManager"),
    getOrNull("EXA").then((d) => d ?? { address: ZeroAddress }),
    getOrNull("EXAPool").then((d) => d ?? { address: ZeroAddress }),
    getOrNull("EXAGauge").then((d) => d ?? { address: ZeroAddress }),
    getOrNull("BeefyEXA").then((d) => d ?? { address: ZeroAddress }),
    getOrNull("BeefyEXABoost").then((d) => d ?? { address: ZeroAddress }),
    getOrNull("PriceFeedETH").then((d) => d ?? { address: ZeroAddress }),
    getOrNull("ExtraLending").then((d) => d ?? { address: ZeroAddress }),
    getNamedAccounts(),
  ]);
  const { address: fixedPreviewer } = await tenderlify(
    "FixedPreviewer",
    await deploy(`FixedPreviewer`, {
      skipIfAlreadyDeployed: !JSON.parse(env[`DEPLOY_FIXED_PREVIEWER`] ?? "false"),
      contract: "FixedPreviewer",
      args: [],
      from: deployer,
      log: true,
    }),
  );
  await validateUpgrade(
    "Previewer",
    { args: [auditor, priceFeedETH, fixedPreviewer], envKey: "PREVIEWER" },
    async (name, opts) =>
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

  if (periphery?.extraReserve == null) return;
  await validateUpgrade(
    "VotePreviewer",
    {
      args: [exa, exaPool, exaGauge, beefyEXA, beefyEXABoost, extraLending, periphery.extraReserve],
      envKey: "VOTE_PREVIEWER",
    },
    async (name, opts) =>
      deploy(name, { ...opts, proxy: { proxyContract: "TransparentUpgradeableProxy" }, from: deployer, log: true }),
  );
};

func.tags = ["Previewers"];
func.dependencies = ["Auditor", "DebtManager", "UniswapV3"];

export default func;
