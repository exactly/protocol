import type { DeployFunction } from "hardhat-deploy/types";
import type { DeadAllower, Firewall } from "../types";
import validateUpgrade from "./.utils/validateUpgrade";
import grantRole from "./.utils/grantRole";
import DEAD_ADDRESS from "./.utils/DEAD_ADDRESS";
import renounceRole from "./.utils/renounceRole";

const func: DeployFunction = async ({
  deployments: { deploy, get },
  ethers: { getContract, getSigner, keccak256, toUtf8Bytes },
  getNamedAccounts,
}) => {
  const [{ address: timelock }, { deployer, multisig, allower }] = await Promise.all([
    get("TimelockController"),
    getNamedAccounts(),
  ]);

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
  await grantRole(firewall, keccak256(toUtf8Bytes("ALLOWER_ROLE")), multisig);
  await grantRole(firewall, keccak256(toUtf8Bytes("ALLOWER_ROLE")), allower);

  if (!(await firewall.isAllowed(DEAD_ADDRESS))) {
    await deploy("DeadAllower", { args: [firewall.target], skipIfAlreadyDeployed: true, from: deployer, log: true });
    const deadAllower = await getContract<DeadAllower>("DeadAllower", await getSigner(deployer));
    await grantRole(firewall, keccak256(toUtf8Bytes("ALLOWER_ROLE")), await deadAllower.getAddress());
    await (await deadAllower.allow()).wait();

    await grantRole(firewall, keccak256(toUtf8Bytes("ALLOWER_ROLE")), deployer);
    await (await firewall.allow(deployer, true)).wait();
    if (deployer !== multisig) await renounceRole(firewall, keccak256(toUtf8Bytes("ALLOWER_ROLE")), deployer);
  }
};

func.tags = ["Firewall"];
func.skip = async ({ network }) => !network.config.verified;

export default func;
