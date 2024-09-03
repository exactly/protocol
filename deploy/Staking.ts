import type { DeployFunction } from "hardhat-deploy/types";
import type { Market, StakedEXA } from "../types";
import transferOwnership from "./.utils/transferOwnership";
import multisigPropose from "./.utils/multisigPropose";
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
  const [market, { address: timelock }, { address: exa }, { deployer, treasury, savings }] = await Promise.all([
    getContract<Market>(`Market${staking.market}`),
    get("TimelockController"),
    get("EXA"),
    getNamedAccounts(),
  ]);

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
                market: market.target,
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

  const allowance = parseUnits(String(staking.allowance), 6);
  if ((await market.allowance(treasury, stEXA.target)) < allowance / 5n) {
    if (treasury !== deployer) {
      await multisigPropose("deployer", market, "approve", [stEXA.target, allowance], "treasury");
    } else await (await market.approve(stEXA.target, allowance)).wait();
  }
};

func.tags = ["Staking"];
func.dependencies = ["Markets", "EXA"];
func.skip = deployEXA.skip;

export default func;
