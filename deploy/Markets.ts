import { env } from "process";
import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor, ERC20, Market, RewardsController } from "../types";
import { mockPrices } from "./mocks/Assets";
import transferOwnership from "./.utils/transferOwnership";
import executeOrPropose from "./.utils/executeOrPropose";
import validateUpgrade from "./.utils/validateUpgrade";
import tenderlify from "./.utils/tenderlify";
import grantRole from "./.utils/grantRole";

const func: DeployFunction = async ({
  network: {
    config: { markets },
  },
  config: {
    finance: { maxFuturePools, ...finance },
  },
  ethers: {
    constants: { AddressZero },
    utils: { parseUnits },
    getContractOrNull,
    getContract,
    getSigner,
  },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [rewards, auditor, { address: timelock }, { deployer, multisig, treasury = AddressZero }] = await Promise.all([
    getContractOrNull<RewardsController>("RewardsController"),
    getContract<Auditor>("Auditor"),
    get("TimelockController"),
    getNamedAccounts(),
  ]);

  const earningsAccumulatorSmoothFactor = parseUnits(String(finance.earningsAccumulatorSmoothFactor));
  const penaltyRate = parseUnits(String(finance.penaltyRatePerDay)).div(86_400);
  const backupFeeRate = parseUnits(String(finance.backupFeeRate));
  const reserveFactor = parseUnits(String(finance.reserveFactor));
  const dampSpeedUp = parseUnits(String(finance.dampSpeed.up));
  const dampSpeedDown = parseUnits(String(finance.dampSpeed.down));
  const treasuryFeeRate = parseUnits(String(finance.treasuryFeeRate ?? 0));

  for (const [symbol, config] of Object.entries(markets)) {
    const { address: interestRateModel } = await tenderlify(
      "InterestRateModel",
      await deploy(`InterestRateModel${symbol}`, {
        skipIfAlreadyDeployed: !JSON.parse(env[`DEPLOY_IRM_${symbol}`] ?? "false"),
        contract: "InterestRateModel",
        args: [
          parseUnits(String(config.fixedCurve.a)),
          parseUnits(String(config.fixedCurve.b)),
          parseUnits(String(config.fixedCurve.maxUtilization)),
          parseUnits(String(config.floatingCurve.a)),
          parseUnits(String(config.floatingCurve.b)),
          parseUnits(String(config.floatingCurve.maxUtilization)),
        ],
        from: deployer,
        log: true,
      }),
    );

    const asset = await getContract<ERC20>(symbol);
    const marketName = `Market${symbol}`;
    await validateUpgrade(
      marketName,
      {
        contract: "Market",
        args: [asset.address, auditor.address],
        envKey: "MARKETS",
        unsafeAllow: ["constructor", "state-variable-immutable"],
      },
      async (name, opts) =>
        deploy(name, {
          ...opts,
          proxy: {
            owner: timelock,
            viaAdminContract: "ProxyAdmin",
            proxyContract: "TransparentUpgradeableProxy",
            execute: {
              init: {
                methodName: "initialize",
                args: [
                  maxFuturePools,
                  earningsAccumulatorSmoothFactor,
                  interestRateModel,
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

    if (symbol === "WETH") {
      await validateUpgrade("MarketETHRouter", { args: [market.address], envKey: "ROUTER" }, async (name, opts) =>
        deploy(name, {
          ...opts,
          proxy: {
            owner: timelock,
            viaAdminContract: "ProxyAdmin",
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

    if ((await market.maxFuturePools()) !== maxFuturePools) {
      await executeOrPropose(market, "setMaxFuturePools", [maxFuturePools]);
    }
    if (!(await market.earningsAccumulatorSmoothFactor()).eq(earningsAccumulatorSmoothFactor)) {
      await executeOrPropose(market, "setEarningsAccumulatorSmoothFactor", [earningsAccumulatorSmoothFactor]);
    }
    if (!(await market.penaltyRate()).eq(penaltyRate)) {
      await executeOrPropose(market, "setPenaltyRate", [penaltyRate]);
    }
    if (!(await market.backupFeeRate()).eq(backupFeeRate)) {
      await executeOrPropose(market, "setBackupFeeRate", [backupFeeRate]);
    }
    if (!(await market.reserveFactor()).eq(reserveFactor)) {
      await executeOrPropose(market, "setReserveFactor", [reserveFactor]);
    }
    if ((await market.interestRateModel()).toLowerCase() !== interestRateModel.toLowerCase()) {
      await executeOrPropose(market, "setInterestRateModel", [interestRateModel]);
    }
    if (!(await market.dampSpeedUp()).eq(dampSpeedUp) || !(await market.dampSpeedDown()).eq(dampSpeedDown)) {
      await executeOrPropose(market, "setDampSpeed", [dampSpeedUp, dampSpeedDown]);
    }
    if (
      (await market.treasury()).toLowerCase() !== treasury.toLowerCase() ||
      !(await market.treasuryFeeRate()).eq(treasuryFeeRate)
    ) {
      if (treasury === AddressZero && !treasuryFeeRate.isZero()) throw new Error("missing treasury");
      await executeOrPropose(market, "setTreasury", [treasury, treasuryFeeRate]);
    }

    const { address: priceFeed } = await get(`${mockPrices[symbol] ? "Mock" : ""}PriceFeed${symbol}`);
    const adjustFactor = parseUnits(String(config.adjustFactor));
    if (!(await auditor.allMarkets()).includes(market.address)) {
      await executeOrPropose(auditor, "enableMarket", [market.address, priceFeed, adjustFactor]);
    } else {
      if ((await auditor.markets(market.address)).priceFeed.toLowerCase() !== priceFeed.toLowerCase()) {
        await executeOrPropose(auditor, "setPriceFeed", [market.address, priceFeed]);
      }
      if (!(await auditor.markets(market.address)).adjustFactor.eq(adjustFactor)) {
        await executeOrPropose(auditor, "setAdjustFactor", [market.address, adjustFactor]);
      }
    }

    const marketRewards = await market.rewardsController?.().catch(() => undefined);
    if (marketRewards) {
      const configRewards = (config.rewards && rewards?.address) || AddressZero;
      if (marketRewards.toLowerCase() !== configRewards.toLowerCase()) {
        await executeOrPropose(market, "setRewardsController", [configRewards]);
      }
    }

    await grantRole(market, await market.PAUSER_ROLE(), multisig);

    await transferOwnership(market, deployer, timelock);
  }

  if (rewards) {
    const newRewards = (
      await Promise.all(
        Object.entries(markets).map(async ([symbol, { rewards: marketRewards }]) => {
          if (!marketRewards) return;

          const market = await getContract<Market>(`Market${symbol}`);
          return Promise.all(
            marketRewards.map(async (cfg) => {
              const [reward, { address: priceFeed }] = await Promise.all([
                getContract<ERC20>(cfg.asset),
                get(`PriceFeed${cfg.asset}`),
              ]);
              const [current, marketDecimals, rewardDecimals] = await Promise.all([
                rewards.rewardConfig(market.address, reward.address),
                market.decimals(),
                reward.decimals(),
              ]);
              if (
                current.priceFeed.toLowerCase() !== priceFeed.toLowerCase() ||
                !current.targetDebt.eq(parseUnits(String(cfg.targetDebt), marketDecimals)) ||
                !current.totalDistribution.eq(parseUnits(String(cfg.totalDistribution), rewardDecimals)) ||
                current.start !== Math.floor(cfg.start.getTime() / 1_000) ||
                !current.distributionPeriod.eq(cfg.distributionPeriod) ||
                !current.undistributedFactor.eq(parseUnits(String(cfg.undistributedFactor))) ||
                !current.flipSpeed.eq(parseUnits(String(cfg.flipSpeed))) ||
                !current.compensationFactor.eq(parseUnits(String(cfg.compensationFactor))) ||
                !current.transitionFactor.eq(parseUnits(String(cfg.transitionFactor))) ||
                !current.borrowAllocationWeightFactor.eq(parseUnits(String(cfg.borrowAllocationWeightFactor))) ||
                !current.depositAllocationWeightAddend.eq(parseUnits(String(cfg.depositAllocationWeightAddend))) ||
                !current.depositAllocationWeightFactor.eq(parseUnits(String(cfg.depositAllocationWeightFactor)))
              ) {
                return {
                  market: market.address,
                  reward: reward.address,
                  priceFeed,
                  targetDebt: parseUnits(String(cfg.targetDebt), marketDecimals),
                  totalDistribution: parseUnits(String(cfg.totalDistribution), rewardDecimals),
                  start: cfg.start,
                  distributionPeriod: cfg.distributionPeriod,
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

    await transferOwnership(rewards, deployer, timelock);
  }

  await transferOwnership(auditor, deployer, timelock);
};

func.tags = ["Markets"];
func.dependencies = ["Auditor", "ProxyAdmin", "TimelockController", "Assets", "PriceFeeds", "RewardsController"];

export default func;
