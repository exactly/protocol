import { task } from "hardhat/config";
import { HardhatUserConfig } from "hardhat/types";
import "@nomiclabs/hardhat-waffle";
import "@openzeppelin/hardhat-upgrades";
import "solidity-coverage";
import "hardhat-abi-exporter";
import "hardhat-deploy";
import "hardhat-deploy-ethers";
import "hardhat-gas-reporter";
import "hardhat-contract-sizer";

import chai from "chai";
import { solidity } from "ethereum-waffle";

import * as dotnev from "dotenv";
import assert from "assert";
dotnev.config();

chai.use(solidity);

if (process.env.FORKING) {
  assert(
    process.env.MAINNET_NODE,
    "specify a mainnet node for mainnet forking in your .env file"
  );
}

task("accounts", "Prints the list of accounts", async (args, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

const forkingHardhatConfig = {
  initialBaseFeePerGas: 0,
  forking: {
    url: `${process.env.MAINNET_NODE}`,
  },
  accounts: {
    mnemonic: process.env.MNEMONIC,
  },
  chainId: 1337,
};

const standaloneHardhatConfig = {
  initialBaseFeePerGas: 0,
  gasPrice: 5000000000,
  accounts: {
    mnemonic: process.env.MNEMONIC,
  },
  chainId: 1337,
};

let config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.4",
      },
    ],
  },
  networks: {
    hardhat:
      process.env.FORKING === "true"
        ? forkingHardhatConfig
        : standaloneHardhatConfig,
  },
  gasReporter: {
    currency: "USD",
    gasPrice: 100,
    enabled: process.env.REPORT_GAS ? true : false,
  },
};
if (process.env.RINKEBY_NODE) {
  config.networks!["rinkeby"] = {
    url: `${process.env.RINKEBY_NODE}`,
    gasPrice: 5000000000,
    accounts: {
      mnemonic: process.env.MNEMONIC,
    },
  };
}
if (process.env.KOVAN_NODE) {
  config.networks!["kovan"] = {
    url: `${process.env.KOVAN_NODE}`,
    gasPrice: 5000000000,
    accounts: {
      mnemonic: process.env.MNEMONIC,
    },
  };
}

export default config;
