import type { BigNumber } from "ethers";
import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor, ERC20, ExactlyOracle, FixedLender, InterestRateModel, TimelockController } from "../types";
import transferOwnership from "./.utils/transferOwnership";
import executeOrPropose from "./.utils/executeOrPropose";
import grantRole from "./.utils/grantRole";

const func: DeployFunction = async ({
  config: {
    finance: {
      adjustFactor,
      penaltyRatePerDay,
      smartPoolReserveFactor,
      dampSpeed: { up, down },
      maxFuturePools,
      accumulatedEarningsSmoothFactor,
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

  const poolAccountingArgs = [
    interestRateModel.address,
    parseUnits(String(penaltyRatePerDay)).div(86_400),
    parseUnits(String(smartPoolReserveFactor)),
    { up: parseUnits(String(up)), down: parseUnits(String(down)) },
  ] as [string, BigNumber, BigNumber, { up: BigNumber; down: BigNumber }];
  const fixedLenderArgs = [maxFuturePools, parseUnits(String(accumulatedEarningsSmoothFactor))] as [number, BigNumber];

  for (const symbol of config.tokens) {
    const token = await getContract<ERC20>(symbol);
    const fixedLenderName = `FixedLender${symbol}`;
    await deploy(fixedLenderName, {
      skipIfAlreadyDeployed: true,
      contract: "FixedLender",
      args: [token.address, ...fixedLenderArgs, auditor.address, ...poolAccountingArgs],
      from: deployer,
      log: true,
    });
    const fixedLender = await getContract<FixedLender>(fixedLenderName, await getSigner(deployer));

    if (symbol === "WETH") {
      await deploy("FixedLenderETHRouter", { args: [fixedLender.address], from: deployer, log: true });
    }

    if (!((await fixedLender.maxFuturePools()) === maxFuturePools)) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setMaxFuturePools", [maxFuturePools]);
    }
    if (!(await fixedLender.accumulatedEarningsSmoothFactor()).eq(fixedLenderArgs[1])) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setAccumulatedEarningsSmoothFactor", [
        fixedLenderArgs[1],
      ]);
    }
    if (!(await fixedLender.penaltyRate()).eq(poolAccountingArgs[1])) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setPenaltyRate", [poolAccountingArgs[1]]);
    }
    if (!(await fixedLender.smartPoolReserveFactor()).eq(poolAccountingArgs[2])) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setSmartPoolReserveFactor", [
        poolAccountingArgs[2],
      ]);
    }
    if (!((await fixedLender.interestRateModel()) === interestRateModel.address)) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setInterestRateModel", [
        interestRateModel.address,
      ]);
    }
    if (
      !(await fixedLender.dampSpeedUp()).eq(poolAccountingArgs[3].up) ||
      !(await fixedLender.dampSpeedDown()).eq(poolAccountingArgs[3].down)
    ) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setDampSpeed", [poolAccountingArgs[3]]);
    }

    const { address: priceFeedAddress } = await get(`PriceFeed${symbol}`);
    if ((await exactlyOracle.assetsSources(fixedLender.address)) !== priceFeedAddress) {
      await executeOrPropose(deployer, timelockController, exactlyOracle, "setAssetSource", [
        fixedLender.address,
        priceFeedAddress,
      ]);
    }

    const underlyingAdjustFactor = parseUnits(String(adjustFactor[symbol] ?? adjustFactor.default));
    if (!(await auditor.getAllMarkets()).includes(fixedLender.address)) {
      await executeOrPropose(deployer, timelockController, auditor, "enableMarket", [
        fixedLender.address,
        underlyingAdjustFactor,
        await token.decimals(),
      ]);
    } else if (!(await auditor.markets(fixedLender.address)).adjustFactor.eq(underlyingAdjustFactor)) {
      await executeOrPropose(deployer, timelockController, auditor, "setAdjustFactor", [
        fixedLender.address,
        underlyingAdjustFactor,
      ]);
    }

    await grantRole(fixedLender, await fixedLender.PAUSER_ROLE(), multisig);

    await transferOwnership(fixedLender, deployer, timelockController.address);
  }

  for (const contract of [auditor, interestRateModel, exactlyOracle]) {
    await transferOwnership(contract, deployer, timelockController.address);
  }
};

func.tags = ["Markets"];
func.dependencies = ["Auditor", "ExactlyOracle", "InterestRateModel", "TimelockController", "Tokens"];

export default func;
