import { MerkleTree } from "merkletreejs";
import type { DeployFunction } from "hardhat-deploy/types";
import type { EXA, EscrowedEXA } from "../types";
import transferOwnership from "./.utils/transferOwnership";
import executeOrPropose from "./.utils/executeOrPropose";
import validateUpgrade from "./.utils/validateUpgrade";
import grantRole from "./.utils/grantRole";
import airdrop from "../scripts/airdrop.json";

const func: DeployFunction = async ({
  network: {
    config: {
      finance: { escrow },
    },
  },
  ethers: { keccak256, parseUnits, getSigner, getContract, AbiCoder },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [{ address: timelock }, { address: sablier }, { address: rewards }, { deployer, treasury, multisig }] =
    await Promise.all([
      get("TimelockController"),
      get("SablierV2LockupLinear"),
      get("RewardsController"),
      getNamedAccounts(),
    ]);

  await validateUpgrade("EXA", { envKey: "EXA" }, async (name, opts) =>
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

  const exa = await getContract<EXA>("EXA", await getSigner(deployer));
  const deployerBalance = await exa.balanceOf(deployer);
  if (deployerBalance !== 0n) await (await exa.transfer(treasury ?? multisig, deployerBalance)).wait();

  const leaves = Object.entries(airdrop).map((t) =>
    keccak256(AbiCoder.defaultAbiCoder().encode(["address", "uint128"], t)),
  );
  const tree = new MerkleTree(leaves, keccak256, { sort: true });
  await validateUpgrade(
    "Airdrop",
    { args: [exa.target, tree.getHexRoot(), sablier], envKey: "AIRDROP" },
    async (name, opts) =>
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

  await validateUpgrade(
    "esEXA",
    { contract: "EscrowedEXA", args: [exa.target, sablier], envKey: "ESCROWED_EXA" },
    async (name, opts) =>
      deploy(name, {
        ...opts,
        proxy: {
          owner: timelock,
          viaAdminContract: { name: "ProxyAdmin" },
          proxyContract: "TransparentUpgradeableProxy",
          execute: {
            init: { methodName: "initialize", args: [escrow.vestingPeriod, parseUnits(String(escrow.reserveRatio))] },
          },
        },
        from: deployer,
        log: true,
      }),
  );
  const esEXA = await getContract<EscrowedEXA>("esEXA", await getSigner(deployer));

  if ((await esEXA.vestingPeriod()) !== BigInt(escrow.vestingPeriod)) {
    await executeOrPropose(esEXA, "setVestingPeriod", [escrow.vestingPeriod]);
  }
  if ((await esEXA.reserveRatio()) !== parseUnits(String(escrow.reserveRatio))) {
    await executeOrPropose(esEXA, "setReserveRatio", [parseUnits(String(escrow.reserveRatio))]);
  }

  await grantRole(esEXA, await esEXA.TRANSFERRER_ROLE(), rewards);
  await transferOwnership(esEXA, deployer, timelock);
};

func.tags = ["EXA"];
func.dependencies = ["Governance", "Sablier", "Rewards"];
func.skip = async ({ network }) => !["optimism", "goerli"].includes(network.name) && network.live;

export default func;
