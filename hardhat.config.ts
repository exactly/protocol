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
  solidity: { version: "0.8.13", settings: { optimizer: { enabled: true, runs: 10_000 } } },
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
    rinkeby: {
      tokens: ["DAI", "WETH"],
      url: env.RINKEBY_NODE ?? "https://rinkeby.infura.io/",
      gnosisSafeTxService: "https://safe-transaction.rinkeby.gnosis.io/",
      ...(env.MNEMONIC && { accounts: { mnemonic: env.MNEMONIC } }),
    },
  },
  namedAccounts: {
    deployer: { default: 0 },
    multisig: {
      default: 0,
      rinkeby: "0x755DF607BA55ff6430FEE0126A52Bf82D1e57F5f",
    },
  },
  finance: {
    collateralFactor: { default: 0.8, WBTC: 0.6 },
    liquidationIncentive: 1.1,
    penaltyRatePerDay: 0.02,
    smartPoolReserveFactor: 0.1,
    dampSpeed: {
      up: 0.0046,
      down: 0.42,
    },
    maxFuturePools: 12,
    accumulatedEarningsSmoothFactor: 2,
    interestRateModel: {
      curveA: 0.72,
      curveB: -0.22,
      maxUtilization: 3,
      fullUtilization: 2,
      smartPoolRate: 0.1,
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
    liquidationIncentive: number;
    penaltyRatePerDay: number;
    smartPoolReserveFactor: number;
    dampSpeed: {
      up: number;
      down: number;
    };
    maxFuturePools: number;
    accumulatedEarningsSmoothFactor: number;
    interestRateModel: {
      curveA: number;
      curveB: number;
      maxUtilization: number;
      fullUtilization: number;
      smartPoolRate: number;
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
    gnosisSafeTxService?: string;
  }

  export interface HardhatNetworkConfig {
    tokens: string[];
    gnosisSafeTxService: string;
  }

  export interface HttpNetworkConfig {
    tokens: string[];
    gnosisSafeTxService: string;
  }
}
