import { task } from "hardhat/config"
import { HardhatUserConfig } from "hardhat/types"
import "@nomiclabs/hardhat-waffle"
import "@openzeppelin/hardhat-upgrades"
import "solidity-coverage"
import "hardhat-abi-exporter"
import "hardhat-deploy"
import "hardhat-deploy-ethers"
import "hardhat-gas-reporter"

import * as fs from 'fs'

task("accounts", "Prints the list of accounts", async (args, hre) => {
  const accounts = await hre.ethers.getSigners()

  for (const account of accounts) {
    console.log(account.address)
  }
});

const ALCHEMY_API_KEY = "DsGLl69IRAWy4BM4fVlUOOlMsr40OWHO"
let PRIVATE_KEY: string

try {
    PRIVATE_KEY = fs.readFileSync('.secret', 'utf8')
    console.log("Deploy Capability Available")
} catch (err) {
    PRIVATE_KEY = "1111111111111111111111111111111111111111111111111111111111111111" // Dummy private key
}

let config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.0"
      },
      {
        version: "0.6.10"
      }
    ]
  }, 
  networks: {
    hardhat: {
      initialBaseFeePerGas: 0
    },
    rinkeby: {
      url: `https://eth-rinkeby.alchemyapi.io/v2/${ALCHEMY_API_KEY}`,
      accounts: [`0x${PRIVATE_KEY}`]
    }
  },
  gasReporter: {
    currency: 'USD',
    gasPrice: 100,
    enabled: process.env.REPORT_GAS ? true : false
  }
}

export default config
