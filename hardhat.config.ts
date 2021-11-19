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

assert(process.env.MNEMONIC, "include a valid mnemonic in your .env file");
assert(
  process.env.FORKING,
  "specify wether to fork mainnet or not in your .env file"
);
assert(
  process.env.ALCHEMY_RINKEBY_API_KEY,
  "specify an alchemy api key for rinkeby access in your .env file"
);
assert(
  process.env.ALCHEMY_KOVAN_API_KEY,
  "specify an alchemy api key for kovan access in your .env file"
);
if (process.env.FORKING) {
  assert(
    process.env.ALCHEMY_MAINNET_API_KEY,
    "specify an alchemy api key for mainnet forking in your .env file"
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
    url: `https://eth-mainnet.alchemyapi.io/v2/${process.env.ALCHEMY_MAINNET_API_KEY}`,
  },
  accounts: {
    mnemonic: process.env.MNEMONIC,
  },
  chainId: 1337,
};

const standaloneHardhatConfig = {
  initialBaseFeePerGas: 0,
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
    rinkeby: {
      url: `https://eth-rinkeby.alchemyapi.io/v2/${process.env.ALCHEMY_RINKEBY_API_KEY}`,
      gasPrice: 5000000000,
      accounts: {
        mnemonic: process.env.MNEMONIC,
      },
    },
    kovan: {
      url: `https://eth-kovan.alchemyapi.io/v2/${process.env.ALCHEMY_KOVAN_API_KEY}`,
      gasPrice: 5000000000,
      accounts: {
        mnemonic: process.env.MNEMONIC,
      },
    },
  },
  gasReporter: {
    currency: "USD",
    gasPrice: 100,
    enabled: process.env.REPORT_GAS ? true : false,
  },
};

export default config;
