import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor, ERC20, Market } from "../types";
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
    getContract,
    getSigner,
  },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [auditor, { address: timelock }, { deployer, multisig, treasury = AddressZero }] = await Promise.all([
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
      await executeOrPropose(auditor, "enableMarket", [
        market.address,
        priceFeed,
        adjustFactor,
        await asset.decimals(),
      ]);
    } else {
      if ((await auditor.markets(market.address)).priceFeed !== priceFeed) {
        await executeOrPropose(auditor, "setPriceFeed", [market.address, priceFeed]);
      }
      if (!(await auditor.markets(market.address)).adjustFactor.eq(adjustFactor)) {
        await executeOrPropose(auditor, "setAdjustFactor", [market.address, adjustFactor]);
      }
    }

    await grantRole(market, await market.PAUSER_ROLE(), multisig);

    await transferOwnership(market, deployer, timelock);
  }

  await transferOwnership(auditor, deployer, timelock);
};

func.tags = ["Markets"];
func.dependencies = ["Auditor", "ProxyAdmin", "TimelockController", "Assets", "PriceFeedWrappers"];

export default func;
