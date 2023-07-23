import { MerkleTree } from "merkletreejs";
import type { DeployFunction } from "hardhat-deploy/types";
import type { EXA } from "../types";
import validateUpgrade from "./.utils/validateUpgrade";
import airdrop from "../scripts/airdrop.json";

const func: DeployFunction = async ({
  ethers: {
    utils: { keccak256, defaultAbiCoder },
    getSigner,
    getContract,
  },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [{ address: timelock }, { address: sablier }, { deployer, treasury, multisig }] = await Promise.all([
    get("TimelockController"),
    get("SablierV2LockupLinear"),
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

  const leaves = Object.entries(airdrop).map((t) => keccak256(defaultAbiCoder.encode(["address", "uint128"], t)));
  const tree = new MerkleTree(leaves, keccak256, { sort: true });
  await validateUpgrade(
    "Airdrop",
    { args: [exa.address, tree.getHexRoot(), sablier], envKey: "AIRDROP" },
    async (name, opts) =>
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
};

func.tags = ["EXA"];
func.dependencies = ["Sablier"];
func.skip = async ({ network }) => !["optimism", "goerli"].includes(network.name) && network.live;

export default func;
