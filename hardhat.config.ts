import "dotenv/config";
import "hardhat-deploy";
import "solidity-coverage";
import "@typechain/hardhat";
import "hardhat-gas-reporter";
import "hardhat-contract-sizer";
import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-waffle";
import "@primitivefi/hardhat-dodoc";
import "@openzeppelin/hardhat-upgrades";
import { env } from "process";
import { task } from "hardhat/config";
import { setup } from "@tenderly/hardhat-tenderly";
import { boolean, string } from "hardhat/internal/core/params/argumentTypes";
import type { HardhatUserConfig as Config } from "hardhat/types";

setup({ automaticVerifications: false });

const config: Config = {
  solidity: { version: "0.8.17", settings: { optimizer: { enabled: true, runs: 200 } } },
  networks: {
    hardhat: {
      accounts: { accountsBalance: `1${"0".repeat(32)}` },
      allowUnlimitedContractSize: true,
    },
    goerli: {
      gnosisSafeTxService: "https://safe-transaction-goerli.safe.global",
      url: env.GOERLI_NODE ?? "https://goerli.infura.io/",
      ...(env.MNEMONIC && { accounts: { mnemonic: env.MNEMONIC } }),
    },
  },
  namedAccounts: {
    deployer: { default: 0 },
    multisig: {
      default: 0,
      goerli: "0x1801f5EAeAbA3fD02cBF4b7ED1A7b58AD84C0705",
    },
  },
  finance: {
    liquidationIncentive: {
      liquidator: 0.05,
      lenders: 0.01,
    },
    penaltyRatePerDay: 0.02,
    backupFeeRate: 0.05,
    reserveFactor: 0.1,
    dampSpeed: {
      up: 0.0046,
      down: 0.42,
    },
    maxFuturePools: 3,
    earningsAccumulatorSmoothFactor: 2,
    interestRateModel: {
      fixedCurve: {
        a: 1.526175,
        b: -0.1695,
        maxUtilization: 7.65,
      },
      floatingCurve: {
        a: 1.526175,
        b: -0.1695,
        maxUtilization: 7.65,
      },
    },
    markets: {
      WETH: {
        adjustFactor: 0.82,
        fixedCurve: {
          a: 1.1568,
          b: -1.0794,
          maxUtilization: 1.0475,
        },
        floatingCurve: {
          a: 0.0174,
          b: 0.0027,
          maxUtilization: 1.007,
        },
      },
      DAI: {
        adjustFactor: 0.95,
        fixedCurve: {
          a: 0.6391,
          b: -0.6175,
          maxUtilization: 1.0105,
        },
        floatingCurve: {
          a: 0.022,
          b: -0.0066,
          maxUtilization: 1.0182,
        },
      },
      USDC: {
        adjustFactor: 0.98,
        fixedCurve: {
          a: 0.6777,
          b: -0.6542,
          maxUtilization: 1.0203,
        },
        floatingCurve: {
          a: 0.0186,
          b: -0.0084,
          maxUtilization: 1.0154,
        },
      },
      WBTC: {
        adjustFactor: 0.85,
        fixedCurve: {
          a: 1.5372,
          b: -1.3898,
          maxUtilization: 1.0865,
        },
        floatingCurve: {
          a: 0.0547,
          b: -0.0335,
          maxUtilization: 1.0216,
        },
      },
    },
  },
  dodoc: { exclude: ["mocks/", "k/", "elin/", "rc/"] },
  tenderly: { project: "exactly", username: "exactly", privateVerification: true },
  typechain: { outDir: "types", target: "ethers-v5" },
  contractSizer: { runOnCompile: true, only: ["^contracts/"], except: ["mocks"] },
  gasReporter: {
    currency: "USD",
    gasPrice: 100,
    enabled: !!JSON.parse(env.REPORT_GAS ?? "false"),
  },
};

task(
  "pause",
  "pauses/unpauses a market",
  async ({ market, pause, account }: { market: string; pause: boolean; account: string }, { ethers }) => {
    const { default: multisigPropose } = await import("./deploy/.utils/multisigPropose");
    await multisigPropose(account, await ethers.getContract(`Market${market}`), pause ? "pause" : "unpause");
  },
)
  .addPositionalParam("market", "symbol of the underlying asset", undefined, string)
  .addOptionalPositionalParam("pause", "whether to pause or unpause the market", true, boolean)
  .addOptionalParam("account", "signer's account name", "deployer", string);

export default config;

declare module "hardhat/types/config" {
  export interface FinanceConfig {
    markets: { [asset: string]: MarketConfig };
    liquidationIncentive: { liquidator: number; lenders: number };
    penaltyRatePerDay: number;
    treasuryFeeRate?: number;
    backupFeeRate: number;
    reserveFactor: number;
    dampSpeed: {
      up: number;
      down: number;
    };
    maxFuturePools: number;
    earningsAccumulatorSmoothFactor: number;
    interestRateModel: {
      fixedCurve: Curve;
      floatingCurve: Curve;
    };
  }

  export interface MarketConfig {
    adjustFactor: number;
    fixedCurve: Curve;
    floatingCurve: Curve;
  }

  export interface Curve {
    a: number;
    b: number;
    maxUtilization: number;
  }

  export interface NetworksUserConfig {
    hardhat?: HardhatNetworkUserConfig;
    mainnet?: MainnetNetworkUserConfig;
  }

  export interface HardhatUserConfig {
    finance: FinanceConfig;
  }

  export interface HardhatConfig {
    finance: FinanceConfig;
  }

  export interface MainnetNetworkUserConfig extends HttpNetworkUserConfig {
    timelockDelay: number;
    priceExpiration: number;
    gnosisSafeTxService: string;
  }

  export interface HttpNetworkUserConfig {
    timelockDelay?: number;
    priceExpiration?: number;
    gnosisSafeTxService?: string;
  }

  export interface HardhatNetworkConfig {
    timelockDelay?: number;
    priceExpiration?: number;
    gnosisSafeTxService: string;
  }

  export interface HttpNetworkConfig {
    timelockDelay?: number;
    priceExpiration?: number;
    gnosisSafeTxService: string;
  }
}
