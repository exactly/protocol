import type { DeployFunction } from "hardhat-deploy/types";
import type { EXA } from "../types";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({
  ethers: { getContract, getSigner },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [{ address: timelock }, { deployer, treasury, multisig }] = await Promise.all([
    get("TimelockController"),
    getNamedAccounts(),
  ]);

  await validateUpgrade("EXA", { envKey: "EXA" }, async (name, opts) =>
    deploy(name, {
      ...opts,
      proxy: {
        owner: timelock,
        viaAdminContract: "ProxyAdmin",
        proxyContract: "TransparentUpgradeableProxy",
        execute: { init: { methodName: "initialize", args: [] } },
      },
      from: deployer,
      log: true,
    }),
  );

  const exa = await getContract<EXA>("EXA", await getSigner(deployer));
  const deployerBalance = (await exa.balanceOf(deployer)).toBigInt();
  if (deployerBalance !== 0n) await (await exa.transfer(treasury ?? multisig, deployerBalance)).wait();
};

func.tags = ["EXA"];
func.skip = async ({ network }) => !["optimism", "goerli"].includes(network.name) && network.live;

export default func;
