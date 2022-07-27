import type { BigNumber } from "ethers";
import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor, ERC20, ExactlyOracle, Market, InterestRateModel, TimelockController } from "../types";
import { mockPrices } from "./mocks/Tokens";
import transferOwnership from "./.utils/transferOwnership";
import executeOrPropose from "./.utils/executeOrPropose";
import grantRole from "./.utils/grantRole";

const func: DeployFunction = async ({
  config: {
    finance: {
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
  network: { config },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [auditor, exactlyOracle, interestRateModel, timelockController, { deployer, multisig }] = await Promise.all([
    getContract<Auditor>("Auditor"),
    getContract<ExactlyOracle>("ExactlyOracle"),
    getContract<InterestRateModel>("InterestRateModel"),
    getContract<TimelockController>("TimelockController"),
    getNamedAccounts(),
  ]);

  const marketArgs = [
    maxFuturePools,
    parseUnits(String(earningsAccumulatorSmoothFactor)),
    auditor.address,
    interestRateModel.address,
    parseUnits(String(penaltyRatePerDay)).div(86_400),
    parseUnits(String(backupFeeRate)),
    parseUnits(String(reserveFactor)),
    { up: parseUnits(String(up)), down: parseUnits(String(down)) },
  ] as [number, BigNumber, string, string, BigNumber, BigNumber, BigNumber, { up: BigNumber; down: BigNumber }];

  for (const symbol of config.tokens) {
    const token = await getContract<ERC20>(symbol);
    const marketName = `Market${symbol}`;
    await deploy(marketName, {
      skipIfAlreadyDeployed: true,
      contract: "Market",
      args: [token.address, ...marketArgs],
      from: deployer,
      log: true,
    });
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
      await executeOrPropose(deployer, timelockController, market, "setMaxFuturePools", [maxFuturePools]);
    }
    if (!(await market.earningsAccumulatorSmoothFactor()).eq(marketArgs[1])) {
      await executeOrPropose(deployer, timelockController, market, "setEarningsAccumulatorSmoothFactor", [
        marketArgs[1],
      ]);
    }
    if (!(await market.penaltyRate()).eq(marketArgs[4])) {
      await executeOrPropose(deployer, timelockController, market, "setPenaltyRate", [marketArgs[4]]);
    }
    if (!(await market.backupFeeRate()).eq(marketArgs[5])) {
      await executeOrPropose(deployer, timelockController, market, "setBackupFeeRate", [marketArgs[5]]);
    }
    if (!(await market.reserveFactor()).eq(marketArgs[6])) {
      await executeOrPropose(deployer, timelockController, market, "setReserveFactor", [marketArgs[6]]);
    }
    if (!((await market.interestRateModel()) === interestRateModel.address)) {
      await executeOrPropose(deployer, timelockController, market, "setInterestRateModel", [interestRateModel.address]);
    }
    if (!(await market.dampSpeedUp()).eq(marketArgs[7].up) || !(await market.dampSpeedDown()).eq(marketArgs[7].down)) {
      await executeOrPropose(deployer, timelockController, market, "setDampSpeed", [marketArgs[7]]);
    }

    const { address: priceFeedAddress } = await get(`${mockPrices[symbol] ? "Mock" : ""}PriceFeed${symbol}`);
    if ((await exactlyOracle.priceFeeds(market.address)) !== priceFeedAddress) {
      await executeOrPropose(deployer, timelockController, exactlyOracle, "setPriceFeed", [
        market.address,
        priceFeedAddress,
      ]);
    }

    const underlyingAdjustFactor = parseUnits(String(adjustFactor[symbol] ?? adjustFactor.default));
    if (!(await auditor.getAllMarkets()).includes(market.address)) {
      await executeOrPropose(deployer, timelockController, auditor, "enableMarket", [
        market.address,
        underlyingAdjustFactor,
        await token.decimals(),
      ]);
    } else if (!(await auditor.markets(market.address)).adjustFactor.eq(underlyingAdjustFactor)) {
      await executeOrPropose(deployer, timelockController, auditor, "setAdjustFactor", [
        market.address,
        underlyingAdjustFactor,
      ]);
    }

    await grantRole(market, await market.PAUSER_ROLE(), multisig);

    await transferOwnership(market, deployer, timelockController.address);
  }

  for (const contract of [auditor, interestRateModel, exactlyOracle]) {
    await transferOwnership(contract, deployer, timelockController.address);
  }
};

func.tags = ["Markets"];
func.dependencies = ["Auditor", "ExactlyOracle", "InterestRateModel", "TimelockController", "Tokens"];

export default func;
