import { task } from "hardhat/config";
import { HardhatUserConfig } from "hardhat/types";
import "@nomiclabs/hardhat-waffle";
import "@openzeppelin/hardhat-upgrades";
import "solidity-coverage";
import "hardhat-abi-exporter";
import "hardhat-deploy";
import "hardhat-deploy-ethers";
import "hardhat-gas-reporter";
import chai from "chai";
import { solidity } from "ethereum-waffle";

import * as dotnev from "dotenv";
dotnev.config();

chai.use(solidity);

task("accounts", "Prints the list of accounts", async (args, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

let config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.0",
      },
      {
        version: "0.6.10",
      },
    ],
  },
  networks: {
    hardhat: {
      initialBaseFeePerGas: 0,
      forking: {
        url: `https://eth-mainnet.alchemyapi.io/v2/${process.env.ALKEMY_MAINNET_API_KEY}`,
      },
      accounts: {
        mnemonic: process.env.MNEMONIC,
      },
    },
    rinkeby: {
      url: `https://eth-rinkeby.alchemyapi.io/v2/${
        process.env.ALKEMY_RINKEBY_API_KEY ?? "DsGLl69IRAWy4BM4fVlUOOlMsr40OWHO"
      }`,
      accounts: process.env.MNEMONIC
        ? {
            mnemonic: process.env.MNEMONIC,
          }
        : [
            `0x1111111111111111111111111111111111111111111111111111111111111111`,
          ],
    },
  },
  gasReporter: {
    currency: "USD",
    gasPrice: 100,
    enabled: process.env.REPORT_GAS ? true : false,
  },
};

export default config;
