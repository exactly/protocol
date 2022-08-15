import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor, ERC20, ExactlyOracle, Market, InterestRateModel } from "../types";
import { mockPrices } from "./mocks/Assets";
import transferOwnership from "./.utils/transferOwnership";
import executeOrPropose from "./.utils/executeOrPropose";
import validateUpgrade from "./.utils/validateUpgrade";
import grantRole from "./.utils/grantRole";

const func: DeployFunction = async ({
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
  const [
    auditor,
    exactlyOracle,
    interestRateModel,
    { address: timelockAddress },
    { deployer, multisig, treasury = AddressZero },
  ] = await Promise.all([
    getContract<Auditor>("Auditor"),
    getContract<ExactlyOracle>("ExactlyOracle"),
    getContract<InterestRateModel>("InterestRateModel"),
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

  for (const symbol of finance.assets) {
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
            owner: timelockAddress,
            viaAdminContract: "ProxyAdmin",
            proxyContract: "TransparentUpgradeableProxy",
            execute: {
              init: {
                methodName: "initialize",
                args: [
                  maxFuturePools,
                  earningsAccumulatorSmoothFactor,
                  interestRateModel.address,
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
            owner: timelockAddress,
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
    if ((await market.interestRateModel()).toLowerCase() !== interestRateModel.address.toLowerCase()) {
      await executeOrPropose(market, "setInterestRateModel", [interestRateModel.address]);
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

    const { address: priceFeedAddress } = await get(`${mockPrices[symbol] ? "Mock" : ""}PriceFeed${symbol}`);
    if ((await exactlyOracle.priceFeeds(market.address)) !== priceFeedAddress) {
      await executeOrPropose(exactlyOracle, "setPriceFeed", [market.address, priceFeedAddress]);
    }

    const adjustFactor = parseUnits(String(finance.adjustFactor[symbol] ?? finance.adjustFactor.default));
    if (!(await auditor.allMarkets()).includes(market.address)) {
      await executeOrPropose(auditor, "enableMarket", [market.address, adjustFactor, await asset.decimals()]);
    } else if (!(await auditor.markets(market.address)).adjustFactor.eq(adjustFactor)) {
      await executeOrPropose(auditor, "setAdjustFactor", [market.address, adjustFactor]);
    }

    await grantRole(market, await market.PAUSER_ROLE(), multisig);

    await transferOwnership(market, deployer, timelockAddress);
  }

  for (const contract of [auditor, interestRateModel, exactlyOracle]) {
    await transferOwnership(contract, deployer, timelockAddress);
  }
};

func.tags = ["Markets"];
func.dependencies = ["Auditor", "ExactlyOracle", "InterestRateModel", "ProxyAdmin", "TimelockController", "Assets"];

export default func;
