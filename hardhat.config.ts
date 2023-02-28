import "dotenv/config";
import "hardhat-deploy";
import "solidity-coverage";
import "@typechain/hardhat";
import "hardhat-gas-reporter";
import "hardhat-contract-sizer";
import "@nomiclabs/hardhat-ethers";
import "@nomicfoundation/hardhat-chai-matchers";
import "@primitivefi/hardhat-dodoc";
import "@openzeppelin/hardhat-upgrades";
import { env } from "process";
import { setup } from "@tenderly/hardhat-tenderly";
import { boolean, string } from "hardhat/internal/core/params/argumentTypes";
import { task, extendConfig } from "hardhat/config";
import type { HardhatUserConfig as Config } from "hardhat/types";

setup({ automaticVerifications: false });

const config: Config = {
  solidity: {
    version: "0.8.17",
    settings: { optimizer: { enabled: true, runs: 200 }, debug: { revertStrings: "strip" } },
  },
  networks: {
    hardhat: {
      accounts: { accountsBalance: (10n ** 32n).toString() },
      priceDecimals: 8,
      allowUnlimitedContractSize: true,
    },
    mainnet: {
      priceDecimals: 18,
      timelockDelay: 12 * 3_600,
      safeTxService: "https://safe-transaction-mainnet.safe.global",
      url: env.MAINNET_NODE ?? "https://mainnet.infura.io/",
      ...(env.MNEMONIC && { accounts: { mnemonic: env.MNEMONIC } }),
    },
    goerli: {
      priceDecimals: 8,
      safeTxService: "https://safe-transaction-goerli.safe.global",
      url: env.GOERLI_NODE ?? "https://goerli.infura.io/",
      ...(env.MNEMONIC && { accounts: { mnemonic: env.MNEMONIC } }),
    },
  },
  namedAccounts: {
    deployer: {
      default: 0,
      mainnet: "0xe61Bdef3FFF4C3CF7A07996DCB8802b5C85B665a",
      goerli: "0xDb90CDB64CfF03f254e4015C4F705C3F3C834400",
    },
    multisig: {
      default: 0,
      mainnet: "0x7A65824d74B0C20730B6eE4929ABcc41Cbe843Aa",
      goerli: "0x1801f5EAeAbA3fD02cBF4b7ED1A7b58AD84C0705",
    },
  },
  finance: {
    liquidationIncentive: {
      liquidator: 0.05,
      lenders: 0.0025,
    },
    penaltyRatePerDay: 0.02,
    backupFeeRate: 0.1,
    reserveFactor: 0.1,
    dampSpeed: {
      up: 0.0046,
      down: 0.4,
    },
    maxFuturePools: 3,
    earningsAccumulatorSmoothFactor: 2,
    markets: {
      WETH: {
        adjustFactor: 0.84,
        floatingCurve: {
          a: 0.0137,
          b: 0.004,
          maxUtilization: 1.0091,
        },
        fixedCurve: {
          a: 0.3143,
          b: -0.3008,
          maxUtilization: 1.0033,
        },
      },
      DAI: {
        adjustFactor: 0.9,
        floatingCurve: {
          a: 0.0085,
          b: 0.0066,
          maxUtilization: 1.0081,
        },
        fixedCurve: {
          a: 0.3758,
          b: -0.3582,
          maxUtilization: 1.0072,
        },
      },
      USDC: {
        adjustFactor: 0.91,
        floatingCurve: {
          a: 0.009,
          b: 0.006,
          maxUtilization: 1.006,
        },
        fixedCurve: {
          a: 0.3023,
          b: -0.2864,
          maxUtilization: 1.0027,
        },
      },
      WBTC: {
        adjustFactor: 0.85,
        floatingCurve: {
          a: 0.0438,
          b: -0.033,
          maxUtilization: 1.0173,
        },
        fixedCurve: {
          a: 0.3236,
          b: -0.3136,
          maxUtilization: 1.0002,
        },
        overrides: {
          mainnet: { priceFeed: "double" },
          goerli: { priceFeed: "double" },
        },
      },
      wstETH: {
        adjustFactor: 0.82,
        floatingCurve: {
          a: 0.02,
          b: -0.0023,
          maxUtilization: 1.0133,
        },
        fixedCurve: {
          a: 0.3143,
          b: -0.3008,
          maxUtilization: 1.0033,
        },
        priceFeed: { wrapper: "stETH", fn: "getPooledEthByShares", baseUnit: 10n ** 18n },
      },
    },
  },
  dodoc: { exclude: ["mocks/", "k/", "elin/", "rc/"] },
  tenderly: { project: "exactly", username: "exactly", privateVerification: false },
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

extendConfig((hardhatConfig, { finance: { markets } }) => {
  for (const [networkName, networkConfig] of Object.entries(hardhatConfig.networks)) {
    const live = !["hardhat", "localhost"].includes(networkName);
    networkConfig.markets = Object.fromEntries(
      Object.entries(markets)
        .filter(([, { networks }]) => !networks || networks.includes(networkName))
        .map(([name, { networks, overrides, ...marketConfig }]) => [
          name,
          { ...marketConfig, ...overrides?.[live ? networkName : Object.keys(overrides)[0]] },
        ]),
    );
  }
});

export default config;

declare module "hardhat/types/config" {
  export interface FinanceConfig {
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
  }

  export interface FinanceUserConfig extends FinanceConfig {
    markets: { [asset: string]: MarketUserConfig };
  }

  export interface MarketConfig {
    adjustFactor: number;
    fixedCurve: Curve;
    floatingCurve: Curve;
    priceFeed?: "double" | { wrapper: string; fn: string; baseUnit: bigint };
    rewards?: {
      asset: string;
      targetDebt: bigint;
      totalDistribution: bigint;
      start: Date;
      distributionPeriod: number;
      undistributedFactor: number;
      flipSpeed: number;
      compensationFactor: number;
      transitionFactor: number;
      borrowAllocationWeightFactor: number;
      depositAllocationWeightAddend: number;
      depositAllocationWeightFactor: number;
    }[];
  }

  export interface MarketUserConfig extends MarketConfig {
    networks?: string[];
    overrides?: { [network: string]: Partial<MarketConfig> };
  }

  export interface Curve {
    a: number;
    b: number;
    maxUtilization: number;
  }

  export interface NetworksUserConfig {
    hardhat?: HardhatNetworkUserConfig;
    mainnet?: HttpNetworkUserConfig;
    goerli?: HttpNetworkUserConfig;
  }

  export interface HardhatUserConfig {
    finance: FinanceUserConfig;
  }

  export interface HardhatConfig {
    finance: FinanceConfig;
  }

  export interface HardhatNetworkUserConfig {
    priceDecimals: number;
  }

  export interface HttpNetworkUserConfig {
    priceDecimals: number;
    timelockDelay?: number;
    safeTxService: string;
  }

  export interface HardhatNetworkConfig {
    priceDecimals: number;
    timelockDelay: undefined;
    safeTxService: undefined;
    markets: { [asset: string]: MarketConfig };
  }

  export interface HttpNetworkConfig {
    priceDecimals: number;
    timelockDelay?: number;
    safeTxService: string;
    markets: { [asset: string]: MarketConfig };
  }
}
