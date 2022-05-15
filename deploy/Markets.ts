import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor, ERC20, ExactlyOracle, FixedLender, InterestRateModel, TimelockController } from "../types";
import transferOwnership from "./.utils/transferOwnership";
import executeOrPropose from "./.utils/executeOrPropose";
import grantRole from "./.utils/grantRole";

const func: DeployFunction = async ({
  config: {
    finance: {
      collateralFactor,
      penaltyRatePerDay,
      smartPoolReserveFactor,
      dampSpeedUp,
      dampSpeedDown,
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
    { up: parseUnits(String(dampSpeedUp)), down: parseUnits(String(dampSpeedDown)) },
  ];
  for (const token of config.tokens) {
    const [{ address: tokenAddress }, tokenContract] = await Promise.all([get(token), getContract<ERC20>(token)]);
    const [symbol, decimals] = await Promise.all([tokenContract.symbol(), tokenContract.decimals()]);

    const fixedLenderName = `FixedLender${symbol}`;
    await deploy(fixedLenderName, {
      skipIfAlreadyDeployed: true,
      contract: "FixedLender",
      args: [
        tokenAddress,
        token,
        maxFuturePools,
        parseUnits(String(accumulatedEarningsSmoothFactor)),
        auditor.address,
        ...poolAccountingArgs,
      ],
      from: deployer,
      log: true,
    });
    const fixedLender = await getContract<FixedLender>(fixedLenderName, await getSigner(deployer));

    if (token === "WETH") {
      await deploy("FixedLenderETHRouter", { args: [fixedLender.address], from: deployer, log: true });
    }

    if (!((await fixedLender.maxFuturePools()) === maxFuturePools)) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setMaxFuturePools", [maxFuturePools]);
    }
    if (
      !(await fixedLender.accumulatedEarningsSmoothFactor()).eq(parseUnits(String(accumulatedEarningsSmoothFactor)))
    ) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setAccumulatedEarningsSmoothFactor", [
        parseUnits(String(accumulatedEarningsSmoothFactor)),
      ]);
    }
    if (!(await fixedLender.penaltyRate()).eq(parseUnits(String(penaltyRatePerDay)).div(86_400))) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setPenaltyRate", [poolAccountingArgs[1]]);
    }
    if (!(await fixedLender.smartPoolReserveFactor()).eq(parseUnits(String(smartPoolReserveFactor)))) {
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
      !(await fixedLender.dampSpeed())[0].eq(parseUnits(String(dampSpeedUp))) ||
      !(await fixedLender.dampSpeed())[1].eq(parseUnits(String(dampSpeedDown)))
    ) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setDampSpeed", [poolAccountingArgs[3]]);
    }

    const underlyingCollateralFactor = parseUnits(String(collateralFactor[token] ?? collateralFactor.default));
    if (!(await auditor.getAllMarkets()).includes(fixedLender.address)) {
      await executeOrPropose(deployer, timelockController, auditor, "enableMarket", [
        fixedLender.address,
        underlyingCollateralFactor,
        symbol,
        token,
        decimals,
      ]);
    } else if (!(await auditor.getMarketData(fixedLender.address))[3].eq(underlyingCollateralFactor)) {
      await executeOrPropose(deployer, timelockController, auditor, "setCollateralFactor", [
        fixedLender.address,
        underlyingCollateralFactor,
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
