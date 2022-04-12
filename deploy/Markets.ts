import type { DeployFunction } from "hardhat-deploy/types";
import type {
  Auditor,
  ERC20,
  ExactlyOracle,
  FixedLender,
  InterestRateModel,
  MaturityPositions,
  TimelockController,
} from "../types";
import { readFile } from "fs/promises";
import transferOwnership from "./.utils/transferOwnership";
import executeOrPropose from "./.utils/executeOrPropose";
import grantRole from "./.utils/grantRole";

const func: DeployFunction = async ({
  config: {
    finance: {
      collateralFactor,
      penaltyRatePerDay,
      smartPoolReserveFactor,
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
  const [auditor, exactlyOracle, interestRateModel, maturityPositions, timelockController, { deployer, multisig }] =
    await Promise.all([
      getContract<Auditor>("Auditor"),
      getContract<ExactlyOracle>("ExactlyOracle"),
      getContract<InterestRateModel>("InterestRateModel"),
      getContract<MaturityPositions>("MaturityPositions"),
      getContract<TimelockController>("TimelockController"),
      getNamedAccounts(),
    ]);

  const poolAccountingArgs = [
    interestRateModel.address,
    parseUnits(String(penaltyRatePerDay)).div(86_400),
    parseUnits(String(smartPoolReserveFactor)),
  ];
  for (const asset of config.assets) {
    const [{ address: assetAddress }, assetContract] = await Promise.all([get(asset), getContract<ERC20>(asset)]);
    const [symbol, decimals] = await Promise.all([assetContract.symbol(), assetContract.decimals()]);

    const fixedLenderName = `FixedLender${symbol}`;
    await deploy(fixedLenderName, {
      skipIfAlreadyDeployed: true,
      contract: "FixedLender",
      args: [
        assetAddress,
        asset,
        maxFuturePools,
        parseUnits(String(accumulatedEarningsSmoothFactor)),
        auditor.address,
        ...poolAccountingArgs,
      ],
      from: deployer,
      log: true,
    });
    const fixedLender = await getContract<FixedLender>(fixedLenderName, await getSigner(deployer));

    if (asset === "WETH") {
      await deploy("FixedLenderETHRouter", { args: [fixedLender.address], from: deployer, log: true });
    }

    if ((await fixedLender.maxFuturePools()) !== maxFuturePools) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setMaxFuturePools", [maxFuturePools]);
    }
    if (
      !(await fixedLender.accumulatedEarningsSmoothFactor()).eq(parseUnits(String(accumulatedEarningsSmoothFactor)))
    ) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setAccumulatedEarningsSmoothFactor", [
        parseUnits(String(accumulatedEarningsSmoothFactor)),
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
    if ((await fixedLender.interestRateModel()) !== interestRateModel.address) {
      await executeOrPropose(deployer, timelockController, fixedLender, "setInterestRateModel", [
        interestRateModel.address,
      ]);
    }

    const underlyingCollateralFactor = parseUnits(String(collateralFactor[asset] ?? collateralFactor.default));
    if (!(await auditor.getAllMarkets()).includes(fixedLender.address)) {
      await executeOrPropose(deployer, timelockController, auditor, "enableMarket", [
        fixedLender.address,
        underlyingCollateralFactor,
        symbol,
        asset,
        decimals,
      ]);
    } else if (!(await auditor.getMarketData(fixedLender.address))[3].eq(underlyingCollateralFactor)) {
      await executeOrPropose(deployer, timelockController, auditor, "setCollateralFactor", [
        fixedLender.address,
        underlyingCollateralFactor,
      ]);
    }

    const assetLogo = (await readFile(`deploy/.logos/${asset}.svg`).catch(() => "")).toString();
    if ((await maturityPositions.logos(asset)) !== assetLogo) {
      await executeOrPropose(deployer, timelockController, maturityPositions, "setLogo", [asset, assetLogo]);
    }

    await grantRole(fixedLender, await fixedLender.PAUSER_ROLE(), multisig);

    await transferOwnership(fixedLender, deployer, timelockController.address);
  }

  for (const contract of [auditor, interestRateModel, exactlyOracle, maturityPositions]) {
    await transferOwnership(contract, deployer, timelockController.address);
  }
};

func.tags = ["Markets"];
func.dependencies = ["Auditor", "ExactlyOracle", "InterestRateModel", "TimelockController", "Assets"];

export default func;
