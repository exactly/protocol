import type { DeployFunction } from "hardhat-deploy/types";
import type { Firewall } from "../types";
import transferOwnership from "./.utils/transferOwnership";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({
  deployments: { deploy, get },
  ethers: { getContract, getSigner },
  getNamedAccounts,
}) => {
  const [{ address: timelock }, { deployer }] = await Promise.all([get("TimelockController"), getNamedAccounts()]);

  await validateUpgrade("Firewall", { envKey: "FIREWALL" }, async (name, opts) =>
    deploy(name, {
      ...opts,
      proxy: {
        owner: timelock,
        viaAdminContract: { name: "ProxyAdmin" },
        proxyContract: "TransparentUpgradeableProxy",
        execute: { init: { methodName: "initialize", args: [] } },
      },
      from: deployer,
      log: true,
    }),
  );

  const firewall = await getContract<Firewall>("Firewall", await getSigner(deployer));
  await transferOwnership(firewall, deployer, timelock);
};

func.tags = ["Firewall"];
func.skip = async ({ network }) => !network.config.verified;

export default func;
