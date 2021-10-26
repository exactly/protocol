import { parseUnits } from "@ethersproject/units";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import fs from "fs";
import assert from 'assert';
import YAML from "yaml";
import { ethers } from "hardhat";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const file = fs.readFileSync("./config.yml", "utf8");
  const config = YAML.parse(file);
  const [deployer] = await hre.getUnnamedAccounts();

  if (hre.network.name === 'hardhat'){
    assert(process.env.FORKING === 'true', 'deploying the ecosystem on a loner node not supported (yet?)');
  }

  let tokensForNetwork = config.token_addresses[hre.network.name].assets;
  let chainlinkFeedRegistryAddress = config.token_addresses[hre.network.name].chainlink_feed_registry;

  const tsUtils = await hre.deployments.deploy("TSUtils", {
      from: deployer,
  });

  const {tokenAddresses, tokenSymbols} = await getTokenParameters(tokensForNetwork);
  const exactlyOracle = await hre.deployments.deploy("ExactlyOracle", {
    from: deployer,
    args: [chainlinkFeedRegistryAddress, tokenSymbols, tokenAddresses, config.token_addresses[hre.network.name].usd_address],
    log: true,
    libraries: {
      TSUtils: tsUtils.address
    }
  });

  const auditor = await hre.deployments.deploy("Auditor", {
    from: deployer,
    args: [exactlyOracle.address],
    log: true,
    libraries: {
      TSUtils: tsUtils.address
    }
  });

  const interestRateModel = await hre.deployments.deploy("DefaultInterestRateModel", {
    from: deployer,
    args: [parseUnits("0.02"), parseUnits("0.07")],
    log: true,
    libraries: {
      TSUtils: tsUtils.address
    }
  });

  async function impersonate(address: string) {
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [address]
    });

    const signer = ethers.provider.getSigner(address);
    return signer;
  }

  for (const symbol of Object.keys(tokensForNetwork)) {
    const { name, address, whale, collateralRate, oracleName, decimals } =
      tokensForNetwork[symbol];
    console.log("------");
    console.log(
      "Exafin for %s will use: %s",
      symbol,
      address,
      auditor.address
    );

    const exafin = await hre.deployments.deploy("Exafin", {
      from: deployer,
      args: [address, oracleName, auditor.address, interestRateModel.address],
      log: true,
      libraries: {
        TSUtils: tsUtils.address
      }
    });

    // We enable this ExaFin Market on Auditor 
    await hre.deployments.execute(
      "Auditor",
      { from: deployer },
      "enableMarket",
      exafin.address,
      parseUnits(collateralRate, 18),
      symbol,
      name
    );

    console.log("Exafin %s deployed to: %s", symbol, exafin.address);

    if (!process.env.PUBLIC_ADDRESS) {
      console.log("Add PUBLIC_ADDRESS key to your .env file");
    } else {
      if (whale) {
        let contract = await ethers.getContractAt("IERC20", address);

        const whaleSigner = await impersonate(whale);
        contract = contract.connect(whaleSigner);

        await contract.transfer(
          process.env.PUBLIC_ADDRESS,
          ethers.utils.parseUnits("100", decimals)
        );

        console.log(`Added 100 ${symbol} to ${process.env.PUBLIC_ADDRESS}`);
      } else {
        console.log(`There is no whale added for ${symbol}`);
      }
    }
  }
};

async function getTokenParameters(tokensForNetwork: any) {
  let tokenAddresses = new Array();
  let tokenSymbols = new Array();
  for (const symbol of Object.keys(tokensForNetwork)) {
    const { oracleName, oracle_address } = tokensForNetwork[symbol];

    tokenSymbols.push(oracleName);
    tokenAddresses.push(oracle_address);
  }

  return {tokenAddresses, tokenSymbols};
}

func.skip = (hre: HardhatRuntimeEnvironment) =>
  Promise.resolve(hre.network.name === "mainnet");
func.tags = ["test"];

export default func;
