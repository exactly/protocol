import "dotenv/config";
import "@nomiclabs/hardhat-waffle";
import "@primitivefi/hardhat-dodoc";
import "@typechain/hardhat";
import "solidity-coverage";
import "hardhat-deploy";
import "hardhat-gas-reporter";
import { env } from "process";
import type { HardhatUserConfig as Config } from "hardhat/types";

const config: Config = {
  solidity: { version: "0.8.4" },
  networks: {
    hardhat: {
      tokens: ["DAI", "WETH", "USDC", "WBTC"],
      accounts: { accountsBalance: `1${"0".repeat(32)}` },
    },
    kovan: {
      tokens: ["DAI", "WETH"],
      url: env.KOVAN_NODE ?? "https://kovan.infura.io/",
      ...(env.MNEMONIC && { accounts: { mnemonic: env.MNEMONIC } }),
    },
  },
  namedAccounts: {
    deployer: { default: 0 },
    multisig: {
      default: 0,
      rinkeby: "0x0820289Cb202DbF23B709D4AC1a346331cd590c4",
    },
  },
  finance: {
    collateralFactor: { default: 0.8, WBTC: 0.6 },
    interestRateModel: {
      curveA: 0.72,
      curveB: -0.22,
      maxUtilizationRate: 3,
      smartPoolRate: 0.1,
    },
    poolAccounting: {
      penaltyRatePerDay: 0.02,
      protocolSpreadFee: 0.028,
    },
  },
  dodoc: { exclude: ["mocks", "k", "elin", "ital"] },
  typechain: { outDir: "types", target: "ethers-v5" },
  gasReporter: {
    currency: "USD",
    gasPrice: 100,
    enabled: !!JSON.parse(env.REPORT_GAS ?? "false"),
  },
};

export default config;

declare module "hardhat/types/config" {
  export interface FinanceConfig {
    collateralFactor: { default: number; [token: string]: number };
    interestRateModel: {
      curveA: number;
      curveB: number;
      maxUtilizationRate: number;
      smartPoolRate: number;
    };
    poolAccounting: {
      penaltyRatePerDay: number;
      protocolSpreadFee: number;
    };
  }

  export interface HardhatUserConfig {
    finance: FinanceConfig;
  }

  export interface HardhatConfig {
    finance: FinanceConfig;
  }

  export interface HardhatNetworkUserConfig {
    tokens: string[];
  }

  export interface HttpNetworkUserConfig {
    tokens: string[];
  }

  export interface HardhatNetworkConfig {
    tokens: string[];
  }

  export interface HttpNetworkConfig {
    tokens: string[];
  }
}
