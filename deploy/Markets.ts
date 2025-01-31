import { env } from "process";
import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor, ERC20, DebtManager, Market, RewardsController } from "../types";
import { mockPrices } from "./mocks/Assets";
import transferOwnership from "./.utils/transferOwnership";
import executeOrPropose from "./.utils/executeOrPropose";
import validateUpgrade from "./.utils/validateUpgrade";
import tenderlify from "./.utils/tenderlify";
import grantRole from "./.utils/grantRole";

const func: DeployFunction = async ({
  network: {
    config: { finance },
    live,
  },
  ethers: { ZeroAddress, parseUnits, getContractOrNull, getContract, getSigner },
  deployments: { deploy, get, getOrNull },
  getNamedAccounts,
}) => {
  const [rewards, debtManager, auditor, pauser, { address: timelock }, { deployer, multisig, treasury = ZeroAddress }] =
    await Promise.all([
      getContractOrNull<RewardsController>("RewardsController"),
      getContractOrNull<DebtManager>("DebtManager"),
      getContract<Auditor>("Auditor"),
      getOrNull("Pauser"),
      get("TimelockController"),
      getNamedAccounts(),
    ]);

  const earningsAccumulatorSmoothFactor = parseUnits(String(finance.earningsAccumulatorSmoothFactor));
  const penaltyRate = parseUnits(String(finance.penaltyRatePerDay)) / 86_400n;
  const backupFeeRate = parseUnits(String(finance.backupFeeRate));
  const reserveFactor = parseUnits(String(finance.reserveFactor));
  const dampSpeedUp = parseUnits(String(finance.dampSpeed.up));
  const dampSpeedDown = parseUnits(String(finance.dampSpeed.down));
  const treasuryFeeRate = parseUnits(String(finance.treasuryFeeRate ?? 0));

  for (const [assetSymbol, config] of Object.entries(finance.markets)) {
    const asset = await getContract<ERC20>(assetSymbol);
    const marketName = `Market${assetSymbol}`;
    await validateUpgrade(
      marketName,
      {
        contract: "Market",
        args: [asset.target, auditor.target],
        envKey: "MARKETS",
        unsafeAllow: ["constructor", "state-variable-immutable"],
      },
      async (name, opts) =>
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
                  assetSymbol,
                  finance.futurePools,
                  earningsAccumulatorSmoothFactor,
                  ZeroAddress, // irm
                  penaltyRate,
                  backupFeeRate,
                  reserveFactor,
                  dampSpeedUp,
                  dampSpeedDown,
                ],
              },
            },
          },
          from: deployer,
          log: true,
        }),
    );

    const market = await getContract<Market>(marketName, await getSigner(deployer));

    if (assetSymbol === "WETH") {
      await validateUpgrade("MarketETHRouter", { args: [market.target], envKey: "ROUTER" }, async (name, opts) =>
        deploy(name, {
          ...opts,
          proxy: {
            owner: timelock,
            viaAdminContract: { name: "ProxyAdmin" },
            proxyContract: "TransparentUpgradeableProxy",
            execute: {
              init: { methodName: "initialize", args: [] },
            },
          },
          from: deployer,
          log: true,
        }),
      );
    }

    const { address: interestRateModel } = await tenderlify(
      "InterestRateModel",
      await deploy(`InterestRateModel${assetSymbol}`, {
        skipIfAlreadyDeployed: !JSON.parse(
          env[`DEPLOY_IRM_${assetSymbol}`] ?? ((await market.interestRateModel()) === ZeroAddress ? "true" : "false"),
        ),
        contract: "InterestRateModel",
        args: [
          {
            minRate: parseUnits(String(config.interestRateModel.minRate)),
            naturalRate: parseUnits(String(config.interestRateModel.naturalRate)),
            maxUtilization: parseUnits(String(config.interestRateModel.maxUtilization)),
            naturalUtilization: parseUnits(String(config.interestRateModel.naturalUtilization)),
            growthSpeed: parseUnits(String(config.interestRateModel.growthSpeed)),
            sigmoidSpeed: parseUnits(String(config.interestRateModel.sigmoidSpeed)),
            spreadFactor: parseUnits(String(config.interestRateModel.spreadFactor)),
            maturitySpeed: parseUnits(String(config.interestRateModel.maturitySpeed)),
            timePreference: parseUnits(String(config.interestRateModel.timePreference)),
            fixedAllocation: parseUnits(String(config.interestRateModel.fixedAllocation)),
            maxRate: parseUnits(String(config.interestRateModel.maxRate)),
          },
          market.target,
        ],
        from: deployer,
        log: true,
      }),
    );

    if ((await market.isFrozen()) !== !!config.frozen) {
      await executeOrPropose(market, "setFrozen", [config.frozen]);
    }
    if ((await market.symbol()) !== `exa${assetSymbol}` || (await market.name()) !== `exactly ${assetSymbol}`) {
      await executeOrPropose(market, "setAssetSymbol", [assetSymbol]);
    }
    if ((await market.maxFuturePools()) !== BigInt(finance.futurePools)) {
      await executeOrPropose(market, "setMaxFuturePools", [finance.futurePools]);
    }
    if ((await market.earningsAccumulatorSmoothFactor()) !== earningsAccumulatorSmoothFactor) {
      await executeOrPropose(market, "setEarningsAccumulatorSmoothFactor", [earningsAccumulatorSmoothFactor]);
    }
    if ((await market.penaltyRate()) !== penaltyRate) {
      await executeOrPropose(market, "setPenaltyRate", [penaltyRate]);
    }
    if ((await market.backupFeeRate()) !== backupFeeRate) {
      await executeOrPropose(market, "setBackupFeeRate", [backupFeeRate]);
    }
    if ((await market.reserveFactor()) !== reserveFactor) {
      await executeOrPropose(market, "setReserveFactor", [reserveFactor]);
    }
    if ((await market.interestRateModel()).toLowerCase() !== interestRateModel.toLowerCase()) {
      await executeOrPropose(market, "setInterestRateModel", [interestRateModel]);
    }
    if ((await market.dampSpeedUp()) !== dampSpeedUp || (await market.dampSpeedDown()) !== dampSpeedDown) {
      await executeOrPropose(market, "setDampSpeed", [dampSpeedUp, dampSpeedDown]);
    }
    if (
      (await market.treasury()).toLowerCase() !== treasury.toLowerCase() ||
      (await market.treasuryFeeRate()) !== treasuryFeeRate
    ) {
      if (treasury === ZeroAddress && treasuryFeeRate !== 0n && live) throw new Error("missing treasury");
      await executeOrPropose(market, "setTreasury", [treasury, treasuryFeeRate]);
    }

    const { address: priceFeed } = await get(`${mockPrices[assetSymbol] ? "Mock" : ""}PriceFeed${assetSymbol}`);
    const adjustFactor = parseUnits(String(config.adjustFactor));
    if (!(await auditor.allMarkets()).includes(market.target as string)) {
      await executeOrPropose(auditor, "enableMarket", [market.target, priceFeed, adjustFactor]);
    } else {
      if ((await auditor.markets(market.target)).priceFeed.toLowerCase() !== priceFeed.toLowerCase()) {
        await executeOrPropose(auditor, "setPriceFeed", [market.target, priceFeed]);
      }
      if ((await auditor.markets(market.target)).adjustFactor !== adjustFactor) {
        await executeOrPropose(auditor, "setAdjustFactor", [market.target, adjustFactor]);
      }
    }

    const marketRewards = await market.rewardsController?.().catch(() => undefined);
    if (marketRewards) {
      const configRewards = (config.rewards && (rewards?.target as string | undefined)) || ZeroAddress;
      if (marketRewards.toLowerCase() !== configRewards.toLowerCase()) {
        await executeOrPropose(market, "setRewardsController", [configRewards]);
      }
    }

    if (
      debtManager &&
      (await auditor.allMarkets()).includes(market.target as string) &&
      (await asset.allowance(debtManager.target, market.target)) === 0n
    ) {
      await (await debtManager.approve(market.target)).wait();
    }

    if (pauser) await grantRole(market, await market.EMERGENCY_ADMIN_ROLE(), pauser.address);

    await grantRole(market, await market.PAUSER_ROLE(), multisig);

    await transferOwnership(market, deployer, timelock);
  }

  if (rewards) {
    await transferOwnership(rewards, deployer, timelock);

    const newRewards = (
      await Promise.all(
        Object.entries(finance.markets).map(async ([assetSymbol, { rewards: marketRewards }]) => {
          if (!marketRewards) return;

          const market = await getContract<Market>(`Market${assetSymbol}`);
          return Promise.all(
            Object.entries(marketRewards).map(async ([asset, cfg]) => {
              const [reward, { address: priceFeed }] = await Promise.all([
                getContract<ERC20>(asset),
                get(`PriceFeed${asset}`),
              ]);
              const [current, marketDecimals, rewardDecimals] = await Promise.all([
                rewards.rewardConfig(market.target, reward.target),
                market.decimals(),
                reward.decimals(),
              ]);
              if (
                current.priceFeed.toLowerCase() !== priceFeed.toLowerCase() ||
                current.targetDebt !== parseUnits(String(cfg.debt), marketDecimals) ||
                current.totalDistribution !== parseUnits(String(cfg.total), rewardDecimals) ||
                current.start !== BigInt(Math.floor(new Date(cfg.start).getTime() / 1_000)) ||
                current.distributionPeriod !== BigInt(cfg.period) ||
                current.undistributedFactor !== parseUnits(String(cfg.undistributedFactor)) ||
                current.flipSpeed !== parseUnits(String(cfg.flipSpeed)) ||
                current.compensationFactor !== parseUnits(String(cfg.compensationFactor)) ||
                current.transitionFactor !== parseUnits(String(cfg.transitionFactor)) ||
                current.borrowAllocationWeightFactor !== parseUnits(String(cfg.borrowAllocationWeightFactor)) ||
                current.depositAllocationWeightAddend !== parseUnits(String(cfg.depositAllocationWeightAddend)) ||
                current.depositAllocationWeightFactor !== parseUnits(String(cfg.depositAllocationWeightFactor))
              ) {
                return {
                  market: market.target,
                  reward: reward.target,
                  priceFeed,
                  targetDebt: parseUnits(String(cfg.debt), marketDecimals),
                  totalDistribution: parseUnits(String(cfg.total), rewardDecimals),
                  start: Math.floor(new Date(cfg.start).getTime() / 1_000),
                  distributionPeriod: cfg.period,
                  undistributedFactor: parseUnits(String(cfg.undistributedFactor)),
                  flipSpeed: parseUnits(String(cfg.flipSpeed)),
                  compensationFactor: parseUnits(String(cfg.compensationFactor)),
                  transitionFactor: parseUnits(String(cfg.transitionFactor)),
                  borrowAllocationWeightFactor: parseUnits(String(cfg.borrowAllocationWeightFactor)),
                  depositAllocationWeightAddend: parseUnits(String(cfg.depositAllocationWeightAddend)),
                  depositAllocationWeightFactor: parseUnits(String(cfg.depositAllocationWeightFactor)),
                };
              }
            }),
          );
        }),
      )
    )
      .flat()
      .filter(Boolean);
    if (newRewards.length) await executeOrPropose(rewards, "config", [newRewards]);
  }

  await transferOwnership(auditor, deployer, timelock);
};

func.tags = ["Markets"];
func.dependencies = ["Auditor", "Governance", "Assets", "PriceFeeds", "Rewards", "Pauser"];

export default func;
