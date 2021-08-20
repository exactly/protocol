import { ethers } from "hardhat"
import fs from 'fs'
import YAML from 'yaml'
const hre = require("hardhat");

async function main() {

  const file = fs.readFileSync('./scripts/config.yml', 'utf8')
  const config = YAML.parse(file)
  const Exafin = await ethers.getContractFactory("Exafin")

  let tokensForNetwork = config.token_addresses[hre.hardhatArguments.network]
  for (const [tokenName, tokenAddress] of Object.entries(tokensForNetwork)) { 
    // We get the contract to deploy
    const exafin = await Exafin.deploy(String(tokenAddress))
    await exafin.deployed()
    console.log("Exafin %s deployed to: ", tokenName, exafin.address)
  }
  
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
