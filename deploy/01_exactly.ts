import { parseUnits } from "@ethersproject/units";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { ethers } from "hardhat";
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

  if (hre.network.name === "hardhat") {
    assert(
      process.env.FORKING === "true",
      "deploying the ecosystem on a loner node not supported (yet?)"
    );
  }

  const { tsUtils, decimalMath, marketsLib, exaLib } = await deployLibraries(
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
      ],
      log: true,
      libraries: {
        TSUtils: tsUtils.address,
      },
    });

    addresses.exactlyOracle = exactlyOracle.address;
  }

  const exaToken = await hre.deployments.deploy("ExaToken", {
    from: deployer,
  });

  addresses.exaToken = exaToken.address;

  const auditor = await hre.deployments.deploy("Auditor", {
    from: deployer,
    args: [exactlyOracle.address, exaToken.address],
    log: true,
    libraries: {
      TSUtils: tsUtils.address,
      DecimalMath: decimalMath.address,
      ExaLib: exaLib.address,
      MarketsLib: marketsLib.address,
    },
  });

  addresses.auditor = auditor.address;

  const interestRateModel = await hre.deployments.deploy("InterestRateModel", {
    from: deployer,
    args: [
      parseUnits("0.07"), // Maturity pool slope rate
      parseUnits("0.07"), // Smart pool slope rate
      parseUnits("0.4"), // High UR slope rate
      parseUnits("0.8"), // Slope change rate
      parseUnits("0.02"), // Base rate
      parseUnits("0.02"), // Penalty rate
    ],
    log: true,
    libraries: {
      TSUtils: tsUtils.address,
    },
  });

  addresses.interestRateModel = interestRateModel.address;

  for (const symbol of Object.keys(tokensForNetwork)) {
    const { name, address, whale, collateralRate, oracleName, decimals } =
      tokensForNetwork[symbol];
    console.log("------");

    const eToken = await hre.deployments.deploy("EToken", {
      from: deployer,
      args: ["e" + name, "e" + oracleName, decimals],
      log: true,
    });

    addresses[`e${oracleName}`] = eToken.address;
    console.log("eToken e%s deployed", oracleName);

    const fixedLender = await hre.deployments.deploy("FixedLender", {
      from: deployer,
      args: [
        address,
        oracleName,
        eToken.address,
        auditor.address,
        interestRateModel.address,
      ],
      log: true,
      libraries: {
        TSUtils: tsUtils.address,
      },
    });

    addresses[`fixedLender${symbol}`] = fixedLender.address;
    console.log(
      "FixedLender for %s uses underlying asset address: %s, etoken address: %s, and auditor address: %s",
      symbol,
      address,
      eToken.address,
      auditor.address
    );

    await uploadToS3(addresses);

    // We set the FixedLender where the eToken is used
    await hre.deployments.execute(
      "EToken",
      { from: deployer },
      "setFixedLender",
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
      if (whale) {
        sendTokens(hre, address, whale, decimals);
        console.log(`Added 100 ${symbol} to ${process.env.PUBLIC_ADDRESS}`);
      } else {
        console.log(`There is no whale added for ${symbol}`);
      }
    }
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

async function deployLibraries(deployer: any, hardhatRuntimeEnvironment: any) {
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
        TSUtils: tsUtils.address,
        DecimalMath: decimalMath.address,
      },
    }
  );
  const exaLib = await hardhatRuntimeEnvironment.deployments.deploy("ExaLib", {
    from: deployer,
    libraries: {
      MarketsLib: marketsLib.address,
      DecimalMath: decimalMath.address,
    },
  });

  return { tsUtils, decimalMath, marketsLib, exaLib };
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
