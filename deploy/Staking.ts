import type { DeployFunction } from "hardhat-deploy/types";
import type { StakedEXA } from "../types";
import transferOwnership from "./.utils/transferOwnership";
import validateUpgrade from "./.utils/validateUpgrade";
import deployEXA from "./EXA";

const func: DeployFunction = async ({
  network: {
    config: {
      finance: { staking },
    },
  },
  ethers: { parseUnits, getSigner, getContract },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [{ address: exa }, { address: market }, { address: timelock }, { deployer, treasury, savings }] =
    await Promise.all([get("EXA"), get(`Market${staking.market}`), get("TimelockController"), getNamedAccounts()]);

  await validateUpgrade("stEXA", { contract: "StakedEXA", envKey: "STAKED_EXA" }, async (name, opts) =>
    deploy(name, {
      ...opts,
      proxy: {
        owner: timelock,
        viaAdminContract: { name: "ProxyAdmin" },
        proxyContract: "TransparentUpgradeableProxy",
        execute: {
          init: {
            methodName: "initialize",
            args: [
              {
                asset: exa,
                minTime: staking.minTime,
                refTime: staking.refTime,
                excessFactor: parseUnits(String(staking.excessFactor)),
                penaltyGrowth: parseUnits(String(staking.penaltyGrowth)),
                penaltyThreshold: parseUnits(String(staking.penaltyThreshold)),
                market,
                provider: treasury,
                savings,
                duration: staking.duration,
                providerRatio: parseUnits(String(staking.penaltyThreshold)),
              },
            ],
          },
        },
      },
      from: deployer,
      log: true,
    }),
  );

  const stEXA = await getContract<StakedEXA>("stEXA", await getSigner(deployer));
  await transferOwnership(stEXA, deployer, timelock);

  await validateUpgrade("StakingPreviewer", { args: [stEXA.target], envKey: "STAKING_PREVIEWER" }, async (name, opts) =>
    deploy(name, {
      ...opts,
      proxy: { proxyContract: "TransparentUpgradeableProxy" },
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["Staking"];
func.dependencies = ["Markets", "EXA"];
func.skip = deployEXA.skip;

export default func;
