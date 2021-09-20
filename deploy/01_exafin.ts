import { parseUnits } from "@ethersproject/units";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import fs from "fs";
import YAML from "yaml";
import { ethers } from "hardhat";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const file = fs.readFileSync("./config.yml", "utf8");
  const config = YAML.parse(file);

  const [deployer] = await hre.getUnnamedAccounts();

  let tokensForNetwork = config.token_addresses[hre.network.name].assets;
  let priceOracleAddress =
    config.token_addresses[hre.network.name].price_oracle;

  const auditor = await hre.deployments.deploy("Auditor", {
    from: deployer,
    args: [priceOracleAddress],
    log: true
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
      args: [address, oracleName, auditor.address],
      log: true
    });

    // We transfer ownership of Exafin to Auditor 
    await hre.deployments.execute(
      "Exafin",
      { from: deployer },
      "transferOwnership",
      auditor.address
    );

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

func.skip = (hre: HardhatRuntimeEnvironment) =>
  Promise.resolve(hre.network.name === "mainnet");
func.tags = ["test"];

export default func;
