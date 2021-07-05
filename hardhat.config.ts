import { task } from "hardhat/config";
import { HardhatUserConfig } from "hardhat/types";
import "@nomiclabs/hardhat-waffle";
import "@nomiclabs/hardhat-solhint";
import "@openzeppelin/hardhat-upgrades";
import "solidity-coverage";
import "hardhat-abi-exporter";
import * as fs from 'fs';

task("accounts", "Prints the list of accounts", async (args, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(await account.address);
  }
});

const ALCHEMY_API_KEY = "DsGLl69IRAWy4BM4fVlUOOlMsr40OWHO";
let config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.0"
      },
      {
        version: "0.6.0"
      }
    ]
  }
}

try {
    const ROPSTEN_PRIVATE_KEY = fs.readFileSync('.secret', 'utf8');
    console.log("Deploy Capability Available")
    config['networks'] = {
      rinkeby: {
        url: `https://eth-rinkeby.alchemyapi.io/v2/${ALCHEMY_API_KEY}`,
        accounts: [`0x${ROPSTEN_PRIVATE_KEY}`]
      }
    }
} catch (err) {}

export default config;
