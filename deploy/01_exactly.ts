import { parseUnits } from "@ethersproject/units";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import fs from "fs";
import assert from "assert";
import YAML from "yaml";
import * as AWS from "aws-sdk";

const IAM_USER_KEY = process.env.AWS_USER_KEY;
const IAM_USER_SECRET = process.env.AWS_USER_SECRET;

const s3bucket = new AWS.S3({
  accessKeyId: IAM_USER_KEY,
  secretAccessKey: IAM_USER_SECRET,
  region: "us-east-1",
});

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const file = fs.readFileSync("./config.yml", "utf8");
  const config = YAML.parse(file);
  const [deployer] = await hre.getUnnamedAccounts();
  const tokensForNetwork = config.tokenAddresses[hre.network.name].assets;
  if (hre.network.name !== "hardhat") {
    assert(process.env.MNEMONIC, "include a valid mnemonic in your .env file");
  }
  if (hre.network.name === "rinkeby") {
    assert(
      process.env.RINKEBY_NODE,
      "specify a rinkeby node in your .env file"
    );
  }
  if (hre.network.name === "kovan") {
    assert(process.env.KOVAN_NODE, "specify a kovan noden your .env file");
  }
  if (process.env.FORKING) {
    assert(
      process.env.MAINNET_NODE,
      "specify a mainnet nodeg in your .env file"
    );
  }

  const { tsUtils, decimalMath, marketsLib } = await deployLibraries(
    deployer,
    hre
  );

  let exactlyOracle;
  const addresses: { [id: string]: string } = {};

  if (hre.network.name === "rinkeby") {
    exactlyOracle = (await ethers.getContractFactory("MockedOracle")).attach(
      config.tokenAddresses[hre.network.name].mockedExactlyOracle
    );
  } else {
    const { tokenAddresses, tokenSymbols } = await getTokenParameters(
      tokensForNetwork
    );
    exactlyOracle = await hre.deployments.deploy("ExactlyOracle", {
      from: deployer,
      args: [
        config.tokenAddresses[hre.network.name].chainlinkFeedRegistry,
        tokenSymbols,
        tokenAddresses,
        config.tokenAddresses[hre.network.name].usdAddress,
        config.tokenAddresses[hre.network.name].maxOracleDelayTime,
      ],
      log: true,
      libraries: {
        TSUtils: tsUtils.address,
      },
    });

    addresses.exactlyOracle = exactlyOracle.address;
  }

  const auditor = await hre.deployments.deploy("Auditor", {
    from: deployer,
    args: [exactlyOracle.address],
    log: true,
    libraries: {
      DecimalMath: decimalMath.address,
      MarketsLib: marketsLib.address,
    },
  });

  addresses.auditor = auditor.address;

  const interestRateModel = await hre.deployments.deploy("InterestRateModel", {
    from: deployer,
    args: [
      parseUnits("0.0495"), // A parameter for the curve
      parseUnits("-0.025"), // B parameter for the curve
      parseUnits("1.1"), // High UR slope rate
      parseUnits("0.0000002314814815"), // Penalty Rate per second. each day (86400) is 2%
      parseUnits("0.1"), // Smart Pool fee rate for debt takeover
    ],
    log: true,
  });

  addresses.interestRateModel = interestRateModel.address;

  const timelockController = await hre.deployments.deploy(
    "TimelockController",
    {
      from: deployer,
      args: [
        config.minTimelockDelay, // in seconds
        [deployer], // proposers addresses
        [deployer], // executors addresses
      ],
      log: true,
    }
  );
  const ADMIN_ROLE = await hre.deployments.read(
    "Auditor",
    { from: deployer },
    "DEFAULT_ADMIN_ROLE"
  );

  for (const symbol of Object.keys(tokensForNetwork)) {
    const { name, whale, collateralRate, decimals, oracleName } =
      tokensForNetwork[symbol];
    console.log("------");
    let address: string;
    if (hre.network.name === "hardhat" && process.env.FORKING !== "true") {
      const totalSupply = ethers.utils.parseUnits("100000000000", decimals);
      let underlyingToken: Contract;
      if (symbol === "WETH") {
        const Weth = await ethers.getContractFactory("WETH9");
        underlyingToken = await Weth.deploy();
        await underlyingToken.deployed();
        if (process.env.PUBLIC_ADDRESS) {
          await underlyingToken.deposit({ value: totalSupply });
        }
      } else {
        const MockedToken = await ethers.getContractFactory("MockedToken");
        underlyingToken = await MockedToken.deploy(
          "Fake " + symbol,
          "F" + symbol,
          decimals,
          totalSupply.toString()
        );
        await underlyingToken.deployed();
      }
      await underlyingToken.deployed();
      if (process.env.PUBLIC_ADDRESS) {
        await underlyingToken.transfer(process.env.PUBLIC_ADDRESS, totalSupply);
      }
      address = underlyingToken.address;
    } else {
      ({ address } = tokensForNetwork[symbol]);
    }

    const fixedLenderDeploymentName = "FixedLender" + symbol;
    const poolAccountingDeploymentName = "PoolAccounting" + symbol;
    const eTokenDeploymentName = "EToken" + symbol;

    const eToken = await hre.deployments.deploy(eTokenDeploymentName, {
      contract: "EToken",
      from: deployer,
      args: ["e" + name, "e" + symbol, decimals],
      log: true,
    });

    addresses[`e${symbol}`] = eToken.address;
    console.log("eToken e%s deployed", symbol);

    const poolAccounting = await hre.deployments.deploy(
      poolAccountingDeploymentName,
      {
        contract: "PoolAccounting",
        from: deployer,
        args: [interestRateModel.address],
        log: true,
        libraries: {
          TSUtils: tsUtils.address,
        },
      }
    );

    const fixedLender = await hre.deployments.deploy(
      fixedLenderDeploymentName,
      {
        contract: symbol === "WETH" ? "ETHFixedLender" : "FixedLender",
        from: deployer,
        args: [
          address,
          oracleName,
          eToken.address,
          auditor.address,
          poolAccounting.address,
        ],
        log: true,
      }
    );
    await grantPauserRole(fixedLenderDeploymentName, deployer, hre, config);

    await transferOwnershipToTimelock(
      fixedLenderDeploymentName,
      deployer,
      timelockController.address,
      ADMIN_ROLE,
      hre
    );

    addresses[fixedLenderDeploymentName] = fixedLender.address;
    console.log(
      "FixedLender for %s uses underlying asset address: %s, etoken address: %s, and auditor address: %s",
      symbol,
      address,
      eToken.address,
      auditor.address
    );

    if (process.env.AWS_KEY_ID) {
      await uploadToS3(addresses);
    } else {
      console.log("skipping address upload");
    }

    // We set the FixedLender where the eToken is used and we set the Auditor that is called in every transfer
    await hre.deployments.execute(
      eTokenDeploymentName,
      { from: deployer },
      "initialize",
      fixedLender.address,
      auditor.address
    );

    // We set the FixedLender on the PoolAccounting
    await hre.deployments.execute(
      poolAccountingDeploymentName,
      { from: deployer },
      "initialize",
      fixedLender.address
    );

    // We enable this FixedLender Market on Auditor
    await hre.deployments.execute(
      "Auditor",
      { from: deployer },
      "enableMarket",
      fixedLender.address,
      parseUnits(collateralRate, 18),
      symbol,
      name,
      decimals
    );

    if (!process.env.PUBLIC_ADDRESS) {
      console.log("Add PUBLIC_ADDRESS key to your .env file");
    } else {
      if (process.env.FORKING === "true") {
        if (whale) {
          sendTokens(hre, address, whale, decimals);
          console.log(`Added 100 ${symbol} to ${process.env.PUBLIC_ADDRESS}`);
        } else {
          console.log(`There is no whale added for ${symbol}`);
        }
      }
    }
  }
  await transferOwnershipToTimelock(
    "Auditor",
    deployer,
    timelockController.address,
    ADMIN_ROLE,
    hre
  );
  await transferOwnershipToTimelock(
    "InterestRateModel",
    deployer,
    timelockController.address,
    ADMIN_ROLE,
    hre
  );
  // If network is rinkeby we don't need to transfer ownership of oracle since it's mocked
  if (hre.network.name !== "rinkeby") {
    await transferOwnershipToTimelock(
      "ExactlyOracle",
      deployer,
      timelockController.address,
      ADMIN_ROLE,
      hre
    );
  }
};

export function uploadToS3(data: { [id: string]: string }) {
  const BUCKET_NAME = "abi-versions";

  return new Promise((resolve, reject) => {
    fs.writeFileSync("/tmp/addresses.json", JSON.stringify(data));

    const params = {
      Bucket: BUCKET_NAME,
      Key: `latest/addresses.json`,
      Body: fs.readFileSync("/tmp/addresses.json", "utf8"),
    };

    s3bucket.upload(params, (err: Error, data: any) => {
      if (err) {
        return reject(err);
      }

      return resolve(data);
    });
  });
}

async function deployLibraries(
  deployer: string,
  hardhatRuntimeEnvironment: any
) {
  const tsUtils = await hardhatRuntimeEnvironment.deployments.deploy(
    "TSUtils",
    {
      from: deployer,
    }
  );
  const decimalMath = await hardhatRuntimeEnvironment.deployments.deploy(
    "DecimalMath",
    {
      from: deployer,
    }
  );
  const marketsLib = await hardhatRuntimeEnvironment.deployments.deploy(
    "MarketsLib",
    {
      from: deployer,
      libraries: {
        DecimalMath: decimalMath.address,
      },
    }
  );

  return { tsUtils, decimalMath, marketsLib };
}

async function transferOwnershipToTimelock(
  contractName: string,
  deployer: string,
  timelockAddress: string,
  adminRole: string,
  hardhatRuntimeEnvironment: any
) {
  await hardhatRuntimeEnvironment.deployments.execute(
    contractName,
    { from: deployer, log: true },
    "grantRole",
    adminRole,
    timelockAddress
  );
  await hardhatRuntimeEnvironment.deployments.execute(
    contractName,
    { from: deployer, log: true },
    "revokeRole",
    adminRole,
    deployer
  );
}

async function grantPauserRole(
  fixedLenderDeploymentName: string,
  deployer: string,
  hardhatRuntimeEnvironment: any,
  config: any
) {
  const PAUSER_ROLE = await hardhatRuntimeEnvironment.deployments.read(
    fixedLenderDeploymentName,
    { from: deployer },
    "PAUSER_ROLE"
  );

  // We grant the PAUSER_ROLE to the multisig if defined in config, else to the deployer
  const multisigAddress =
    config.tokenAddresses[hardhatRuntimeEnvironment.network.name]
      .multisigAddress;
  const granteeAddress = multisigAddress ? multisigAddress : deployer;
  await hardhatRuntimeEnvironment.deployments.execute(
    fixedLenderDeploymentName,
    { from: deployer },
    "grantRole",
    PAUSER_ROLE,
    granteeAddress
  );
}

async function getTokenParameters(tokensForNetwork: any) {
  let tokenAddresses = new Array();
  let tokenSymbols = new Array();
  for (const symbol of Object.keys(tokensForNetwork)) {
    const { oracleName, oracleAddress } = tokensForNetwork[symbol];

    tokenSymbols.push(oracleName);
    tokenAddresses.push(oracleAddress);
  }

  return { tokenAddresses, tokenSymbols };
}

async function sendTokens(
  hardhatRuntimeEnvironment: any,
  tokenAddress: string,
  whale: string,
  decimals: any
) {
  let contract = await ethers.getContractAt("IERC20", tokenAddress);

  const whaleSigner = await impersonate(hardhatRuntimeEnvironment, whale);
  contract = contract.connect(whaleSigner);

  await contract.transfer(
    process.env.PUBLIC_ADDRESS,
    ethers.utils.parseUnits("100", decimals)
  );
}

async function impersonate(hardhatRuntimeEnvironment: any, address: string) {
  await hardhatRuntimeEnvironment.network.provider.request({
    method: "hardhat_impersonateAccount",
    params: [address],
  });

  const signer = ethers.provider.getSigner(address);
  return signer;
}

func.skip = (hre: HardhatRuntimeEnvironment) =>
  Promise.resolve(hre.network.name === "mainnet");
func.tags = ["test"];

export default func;
