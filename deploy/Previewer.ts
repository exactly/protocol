import type { DeployFunction } from "hardhat-deploy/types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({
  ethers: {
    constants: { AddressZero },
  },
  deployments: { deploy, get, getOrNull },
  getNamedAccounts,
}) => {
  const { deployer } = await getNamedAccounts();
  await validateUpgrade(
    "Previewer",
    {
      args: [(await get("Auditor")).address, (await getOrNull("PriceFeedETH"))?.address ?? AddressZero],
      envKey: "PREVIEWER",
    },
    async (name, opts) =>
      deploy(name, {
        ...opts,
        proxy: { proxyContract: "TransparentUpgradeableProxy" },
        from: deployer,
        log: true,
      }),
  );
};

func.tags = ["Previewer"];
func.dependencies = ["Auditor"];

export default func;
