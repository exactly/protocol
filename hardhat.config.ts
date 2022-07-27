import "dotenv/config";
import "@nomiclabs/hardhat-waffle";
import "@primitivefi/hardhat-dodoc";
import "@typechain/hardhat";
import "solidity-coverage";
import "hardhat-deploy";
import "hardhat-gas-reporter";
import { env } from "process";
import { task } from "hardhat/config";
import { boolean, string } from "hardhat/internal/core/params/argumentTypes";
import type { HardhatUserConfig as Config } from "hardhat/types";
import multisigPropose from "./deploy/.utils/multisigPropose";

const config: Config = {
  solidity: { version: "0.8.13", settings: { optimizer: { enabled: true, runs: 200 } } },
  networks: {
    hardhat: {
      tokens: ["DAI", "WETH", "USDC", "WBTC"],
      accounts: { accountsBalance: `1${"0".repeat(32)}` },
      allowUnlimitedContractSize: true,
    },
    rinkeby: {
      tokens: ["DAI", "WETH", "USDC", "WBTC"],
      gnosisSafeTxService: "https://safe-transaction.rinkeby.gnosis.io/",
      url: env.RINKEBY_NODE ?? "https://rinkeby.infura.io/",
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
    adjustFactor: { default: 0.8, WBTC: 0.6 },
    liquidationIncentive: {
      liquidator: 0.05,
      lenders: 0.01,
    },
    penaltyRatePerDay: 0.02,
    backupFeeRate: 0.1,
    smartPoolReserveFactor: 0.1,
    dampSpeed: {
      up: 0.0046,
      down: 0.42,
    },
    maxFuturePools: 3,
    accumulatedEarningsSmoothFactor: 2,
    interestRateModel: {
      fixedCurve: {
        a: 1.526175,
        b: -0.1695,
        maxUtilization: 7.65,
      },
      fixedFullUtilization: 7.5,
      floatingCurve: {
        a: 1.526175,
        b: -0.1695,
        maxUtilization: 7.65,
      },
      floatingFullUtilization: 7.5,
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

task(
  "pause",
  "pauses/unpauses a market",
  async ({ market, pause, account }: { market: string; pause: boolean; account: string }, hre) =>
    multisigPropose(hre, account, await hre.ethers.getContract(`Market${market}`), pause ? "pause" : "unpause"),
)
  .addPositionalParam("market", "token symbol of the underlying asset", undefined, string)
  .addOptionalPositionalParam("pause", "whether to pause or unpause the market", true, boolean)
  .addOptionalParam("account", "signer's account name", "deployer", string);

export default config;

declare module "hardhat/types/config" {
  export interface Curve {
    a: number;
    b: number;
    maxUtilization: number;
  }
  export interface FinanceConfig {
    adjustFactor: { default: number; [token: string]: number };
    liquidationIncentive: { liquidator: number; lenders: number };
    penaltyRatePerDay: number;
    backupFeeRate: number;
    smartPoolReserveFactor: number;
    dampSpeed: {
      up: number;
      down: number;
    };
    maxFuturePools: number;
    accumulatedEarningsSmoothFactor: number;
    interestRateModel: {
      fixedCurve: Curve;
      fixedFullUtilization: number;
      floatingCurve: Curve;
      floatingFullUtilization: number;
    };
  }

  export interface NetworksUserConfig {
    hardhat?: HardhatNetworkUserConfig;
    mainnet?: MainnetNetworkUserConfig;
    [networkName: string]: NetworkUserConfig;
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

  export interface MainnetNetworkUserConfig extends HttpNetworkUserConfig {
    timelockDelay: number;
    priceExpiration: number;
    gnosisSafeTxService: string;
  }

  export interface HttpNetworkUserConfig {
    tokens: string[];
    timelockDelay?: number;
    priceExpiration?: number;
    gnosisSafeTxService?: string;
  }

  export interface HardhatNetworkConfig {
    tokens: string[];
    timelockDelay?: number;
    priceExpiration?: number;
    gnosisSafeTxService: string;
  }

  export interface HttpNetworkConfig {
    tokens: string[];
    timelockDelay?: number;
    priceExpiration?: number;
    gnosisSafeTxService: string;
  }
}
