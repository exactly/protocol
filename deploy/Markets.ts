import type { BigNumber } from "ethers";
import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor, ERC20, ExactlyOracle, Market, InterestRateModel } from "../types";
import { mockPrices } from "./mocks/Assets";
import transferOwnership from "./.utils/transferOwnership";
import executeOrPropose from "./.utils/executeOrPropose";
import validateUpgrade from "./.utils/validateUpgrade";
import grantRole from "./.utils/grantRole";

const func: DeployFunction = async ({
  config: {
    finance: {
      assets,
      adjustFactor,
      penaltyRatePerDay,
      backupFeeRate,
      reserveFactor,
      dampSpeed: { up, down },
      maxFuturePools,
      earningsAccumulatorSmoothFactor,
    },
  },
  ethers: {
    utils: { parseUnits },
    getContract,
    getSigner,
  },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [auditor, exactlyOracle, interestRateModel, { address: timelockAddress }, { deployer, multisig }] =
    await Promise.all([
      getContract<Auditor>("Auditor"),
      getContract<ExactlyOracle>("ExactlyOracle"),
      getContract<InterestRateModel>("InterestRateModel"),
      get("TimelockController"),
      getNamedAccounts(),
    ]);

  const marketArgs = [
    maxFuturePools,
    parseUnits(String(earningsAccumulatorSmoothFactor)),
    interestRateModel.address,
    parseUnits(String(penaltyRatePerDay)).div(86_400),
    parseUnits(String(backupFeeRate)),
    parseUnits(String(reserveFactor)),
    { up: parseUnits(String(up)), down: parseUnits(String(down)) },
  ] as [number, BigNumber, string, BigNumber, BigNumber, BigNumber, { up: BigNumber; down: BigNumber }];

  for (const symbol of assets) {
    const asset = await getContract<ERC20>(symbol);
    const marketName = `Market${symbol}`;
    await validateUpgrade(
      marketName,
      { contract: "Market", args: [asset.address, auditor.address] },
      async (name, opts) =>
        deploy(name, {
          ...opts,
          proxy: {
            owner: timelockAddress,
            viaAdminContract: "ProxyAdmin",
            proxyContract: "TransparentUpgradeableProxy",
            execute: {
              init: { methodName: "initialize", args: marketArgs },
            },
          },
          from: deployer,
          log: true,
        }),
    );

    const market = await getContract<Market>(marketName, await getSigner(deployer));

    if (symbol === "WETH") {
      await deploy("MarketETHRouter", {
        skipIfAlreadyDeployed: true,
        args: [market.address],
        from: deployer,
        log: true,
      });
    }

    if (!((await market.maxFuturePools()) === maxFuturePools)) {
      await executeOrPropose(market, "setMaxFuturePools", [maxFuturePools]);
    }
    if (!(await market.earningsAccumulatorSmoothFactor()).eq(marketArgs[1])) {
      await executeOrPropose(market, "setEarningsAccumulatorSmoothFactor", [marketArgs[1]]);
    }
    if (!(await market.penaltyRate()).eq(marketArgs[3])) {
      await executeOrPropose(market, "setPenaltyRate", [marketArgs[4]]);
    }
    if (!(await market.backupFeeRate()).eq(marketArgs[4])) {
      await executeOrPropose(market, "setBackupFeeRate", [marketArgs[5]]);
    }
    if (!(await market.reserveFactor()).eq(marketArgs[5])) {
      await executeOrPropose(market, "setReserveFactor", [marketArgs[6]]);
    }
    if (!((await market.interestRateModel()) === interestRateModel.address)) {
      await executeOrPropose(market, "setInterestRateModel", [interestRateModel.address]);
    }
    if (!(await market.dampSpeedUp()).eq(marketArgs[6].up) || !(await market.dampSpeedDown()).eq(marketArgs[6].down)) {
      await executeOrPropose(market, "setDampSpeed", [marketArgs[6]]);
    }

    const { address: priceFeedAddress } = await get(`${mockPrices[symbol] ? "Mock" : ""}PriceFeed${symbol}`);
    if ((await exactlyOracle.priceFeeds(market.address)) !== priceFeedAddress) {
      await executeOrPropose(exactlyOracle, "setPriceFeed", [market.address, priceFeedAddress]);
    }

    const underlyingAdjustFactor = parseUnits(String(adjustFactor[symbol] ?? adjustFactor.default));
    if (!(await auditor.allMarkets()).includes(market.address)) {
      await executeOrPropose(auditor, "enableMarket", [market.address, underlyingAdjustFactor, await asset.decimals()]);
    } else if (!(await auditor.markets(market.address)).adjustFactor.eq(underlyingAdjustFactor)) {
      await executeOrPropose(auditor, "setAdjustFactor", [market.address, underlyingAdjustFactor]);
    }

    await grantRole(market, await market.PAUSER_ROLE(), multisig);

    await transferOwnership(market, deployer, timelockAddress);
  }

  for (const contract of [auditor, interestRateModel, exactlyOracle]) {
    await transferOwnership(contract, deployer, timelockAddress);
  }
};

func.tags = ["Markets"];
func.dependencies = ["Auditor", "ExactlyOracle", "InterestRateModel", "TimelockController", "Assets"];

export default func;
