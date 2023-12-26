import "dotenv/config";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-chai-matchers";
import "@openzeppelin/hardhat-upgrades";
import "@typechain/hardhat";
import "hardhat-deploy";
import "hardhat-deploy-ethers";
import "hardhat-contract-sizer";
import "hardhat-gas-reporter";
import "solidity-coverage";
import { env } from "process";
import { setup } from "@tenderly/hardhat-tenderly";
import { boolean, string } from "hardhat/internal/core/params/argumentTypes";
import { task, extendConfig } from "hardhat/config";
import { defaultHdAccountsConfigParams } from "hardhat/internal/core/config/default-config";
import type { HardhatUserConfig as Config } from "hardhat/types";

setup({ automaticVerifications: false });

const hardhatConfig: Config = {
  solidity: {
    version: "0.8.23",
    settings: { evmVersion: "shanghai", optimizer: { enabled: true, runs: 200 }, debug: { revertStrings: "strip" } },
  },
  networks: {
    ethereum: {
      priceDecimals: 18,
      timelockDelay: 24 * 3_600,
      finance: { treasuryFeeRate: 0, futurePools: 3 },
      url: env.ETHEREUM_NODE ?? "",
    },
    optimism: { priceDecimals: 8, timelockDelay: 24 * 3_600, url: env.OPTIMISM_NODE ?? "" },
    goerli: { priceDecimals: 8, url: env.GOERLI_NODE ?? "" },
  },
  namedAccounts: {
    deployer: {
      default: 0,
      ethereum: "0xe61Bdef3FFF4C3CF7A07996DCB8802b5C85B665a",
      optimism: "0xe61Bdef3FFF4C3CF7A07996DCB8802b5C85B665a",
      goerli: "0xDb90CDB64CfF03f254e4015C4F705C3F3C834400",
    },
    multisig: {
      default: 0,
      ethereum: "0x7A65824d74B0C20730B6eE4929ABcc41Cbe843Aa",
      optimism: "0xC0d6Bc5d052d1e74523AD79dD5A954276c9286D3",
      goerli: "0x1801f5EAeAbA3fD02cBF4b7ED1A7b58AD84C0705",
    },
    treasury: {
      optimism: "0x23fD464e0b0eE21cEdEb929B19CABF9bD5215019",
      goerli: "0x1801f5EAeAbA3fD02cBF4b7ED1A7b58AD84C0705",
    },
  },
  finance: {
    treasuryFeeRate: 0.2,
    liquidationIncentive: { liquidator: 0.05, lenders: 0.0025 },
    penaltyRatePerDay: 0.0045,
    backupFeeRate: 0.1,
    reserveFactor: 0.1,
    dampSpeed: { up: 0.0046, down: 0.4 },
    futurePools: 6,
    earningsAccumulatorSmoothFactor: 2,
    interestRateModel: {
      minRate: 2e-2,
      naturalRate: 6e-2,
      maxUtilization: 1.3,
      naturalUtilization: 0.7,
      growthSpeed: 1.1,
      sigmoidSpeed: 2.5,
      spreadFactor: 0.2,
      maturitySpeed: 0.5,
      timePreference: 0.01,
      fixedAllocation: 0.6,
      maxRate: 0.1,
    },
    rewards: {
      undistributedFactor: 0.5,
      flipSpeed: 2,
      compensationFactor: 0.85,
      transitionFactor: 0.83,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02,
      depositAllocationWeightFactor: 0.01,
    },
    escrow: {
      vestingPeriod: 365 * 86_400,
      reserveRatio: 0.25,
    },
    markets: {
      WETH: {
        adjustFactor: 0.86,
        interestRateModel: { maxRate: 4.2 },
        overrides: {
          goerli: {
            rewards: {
              OP: { total: 180_000, debt: 16_000, start: "2023-03-09", period: 32 * 7 * 86_400 },
              EXA: { total: 15_200, debt: 16_000, start: "2023-07-20", period: 8 * 7 * 86_400 },
              esEXA: { total: 150_000, debt: 6_000, start: "2023-10-11", period: 30 * 7 * 86_400 },
            },
          },
          optimism: {
            rewards: {
              OP: {
                total: 180_000,
                debt: 1,
                start: "2023-04-03T14:00Z",
                period: 32 * 7 * 86_400,
                undistributedFactor: 1_000,
                compensationFactor: 0.7,
                transitionFactor: 0.7056,
                depositAllocationWeightAddend: 0.03,
              },
              EXA: {
                total: 15_200,
                debt: 1_000,
                start: "2023-07-24T14:00Z",
                period: 8 * 7 * 86_400,
                undistributedFactor: 1,
                compensationFactor: 0.7,
                transitionFactor: 0.7056,
                depositAllocationWeightAddend: 0.03,
              },
              esEXA: {
                total: 300_000,
                debt: 1_111,
                start: "2023-10-23T14:00Z",
                period: 30 * 7 * 86_400,
                undistributedFactor: 0.65,
                compensationFactor: 0.7,
                transitionFactor: 0.7056,
                depositAllocationWeightAddend: 0.03,
              },
            },
          },
        },
      },
      DAI: {
        networks: ["ethereum", "goerli"],
        adjustFactor: 0.9,
      },
      USDC: {
        adjustFactor: 0.91,
        overrides: {
          goerli: {
            rewards: {
              OP: { total: 420_000, debt: 25_000_000, start: "2023-03-09", period: 32 * 7 * 86_400 },
              EXA: { total: 30_000, debt: 25_000_000, start: "2023-07-20", period: 8 * 7 * 86_400 },
              esEXA: { total: 300_000, debt: 25_000_000, start: "2023-10-11", period: 30 * 7 * 86_400 },
            },
          },
          optimism: {
            rewards: {
              OP: { total: 420_000, debt: 7_500_000, start: "2023-04-03T14:00Z", period: 32 * 7 * 86_400 },
              EXA: {
                total: 30_000,
                debt: 5_000_000,
                start: "2023-07-24T14:00Z",
                period: 8 * 7 * 86_400,
                undistributedFactor: 1,
              },
              esEXA: {
                total: 600_000,
                debt: 6_000_000,
                start: "2023-10-23T14:00Z",
                period: 30 * 7 * 86_400,
                undistributedFactor: 0.3,
              },
            },
          },
        },
      },
      WBTC: {
        adjustFactor: 0.85,
        overrides: {
          ethereum: { priceFeed: "double" },
          goerli: {
            priceFeed: "double",
            rewards: {
              esEXA: { total: 12_000, debt: 0.35, start: "2023-12-20", period: 23 * 7 * 86_400 },
            },
          },
          optimism: {
            adjustFactor: 0.78,
            rewards: {
              esEXA: {
                total: 12_000,
                debt: 0.35,
                undistributedFactor: 0.3,
                transitionFactor: 0.6,
                compensationFactor: 0,
                depositAllocationWeightAddend: 0.06,
                start: "2023-12-20",
                period: 23 * 7 * 86_400,
              },
            },
          },
        },
      },
      wstETH: {
        adjustFactor: 0.82,
        priceFeed: { wrapper: "stETH", fn: "getPooledEthByShares", baseUnit: 10n ** 18n },
        overrides: {
          goerli: {
            rewards: {
              OP: {
                total: 30,
                debt: 1,
                start: "2023-06-13",
                period: 20 * 7 * 86_400,
                compensationFactor: 0,
                transitionFactor: 0.64,
                depositAllocationWeightAddend: 0.03,
              },
              EXA: {
                total: 14,
                debt: 1,
                start: "2023-07-20",
                period: 8 * 7 * 86_400,
                compensationFactor: 0,
                transitionFactor: 0.64,
                depositAllocationWeightAddend: 0.03,
              },
              esEXA: { total: 7, debt: 1, start: "2023-10-11", period: 30 * 7 * 86_400 },
            },
          },
          optimism: {
            priceFeed: undefined,
            rewards: {
              OP: {
                total: 15_500,
                debt: 1,
                start: "2023-06-26T14:00Z",
                period: 20 * 7 * 86_400,
                compensationFactor: 0,
                transitionFactor: 0.64,
                depositAllocationWeightAddend: 0.03,
              },
              EXA: {
                total: 5_400,
                debt: 1,
                start: "2023-07-24T14:00Z",
                period: 8 * 7 * 86_400,
                undistributedFactor: 1,
                compensationFactor: 0,
                transitionFactor: 0.64,
                depositAllocationWeightAddend: 0.03,
              },
              esEXA: {
                total: 70_000,
                debt: 0.05,
                start: "2023-10-23T14:00Z",
                period: 30 * 7 * 86_400,
                compensationFactor: 0,
                transitionFactor: 0.64,
                depositAllocationWeightAddend: 0.03,
              },
            },
          },
        },
      },
      OP: {
        networks: ["optimism"],
        adjustFactor: 0.58,
        overrides: {
          optimism: {
            rewards: {
              EXA: {
                total: 2_300,
                debt: 1,
                start: "2023-07-24T14:00Z",
                period: 8 * 7 * 86_400,
                undistributedFactor: 1_000,
                compensationFactor: 0.7,
                transitionFactor: 0.7056,
                depositAllocationWeightAddend: 0.03,
              },
              esEXA: {
                total: 30_000,
                debt: 730_000,
                start: "2023-10-23T14:00Z",
                period: 30 * 7 * 86_400,
                undistributedFactor: 0.3,
                compensationFactor: 0.85,
                transitionFactor: 0.364,
                depositAllocationWeightAddend: 0.03,
              },
            },
          },
        },
      },
    },
    periphery: {
      optimism: {
        extraReserve: 50,
        uniswapFees: [
          { assets: ["WETH", "OP"], fee: 0.3 },
          { assets: ["USDC", "OP"], fee: 0.3 },
          { assets: ["USDC", "WETH"], fee: 0.05 },
          { assets: ["WETH", "wstETH"], fee: 0.01 },
          { assets: ["USDC", "wstETH"], fee: 0.05 },
        ],
      },
      ethereum: {
        uniswapFees: [
          { assets: ["WETH", "DAI"], fee: 0.05 },
          { assets: ["USDC", "DAI"], fee: 0.01 },
          { assets: ["WETH", "WBTC"], fee: 0.3 },
          { assets: ["USDC", "WBTC"], fee: 0.3 },
          { assets: ["USDC", "WETH"], fee: 0.05 },
          { assets: ["WETH", "wstETH"], fee: 0.01 },
          { assets: ["USDC", "wstETH"], fee: 0.05 },
          { assets: ["DAI", "WBTC"], fee: 0.3 },
        ],
      },
      goerli: {
        uniswapFees: [
          { assets: ["USDC", "WBTC"], fee: 0.05 },
          { assets: ["DAI", "WBTC"], fee: 0.05 },
          { assets: ["DAI", "USDC"], fee: 0.05 },
        ],
      },
    },
  },
  mocha: { timeout: 66_666 },
  paths: { artifacts: "artifacts/hardhat" },
  tenderly: { project: "exactly", username: "exactly", privateVerification: false },
  typechain: { outDir: "types", target: "ethers-v6" },
  contractSizer: { runOnCompile: true, only: ["^contracts/"], except: ["mocks"] },
  gasReporter: { currency: "USD", gasPrice: 100, enabled: !!JSON.parse(env.REPORT_GAS ?? "false") },
};
export default hardhatConfig;

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

extendConfig((extendedConfig, { finance }) => {
  delete (extendedConfig as any).finance; // eslint-disable-line @typescript-eslint/no-explicit-any
  for (const [networkName, networkConfig] of Object.entries(extendedConfig.networks)) {
    const live = !["hardhat", "localhost"].includes(networkName);
    if (live) {
      if (env.MNEMONIC) networkConfig.accounts = { ...defaultHdAccountsConfigParams, mnemonic: env.MNEMONIC };
    } else Object.assign(networkConfig, { priceDecimals: 8, allowUnlimitedContractSize: true });
    networkConfig.finance = {
      ...finance,
      ...networkConfig.finance,
      markets: Object.fromEntries(
        Object.entries(finance.markets)
          .filter(([, { networks }]) => !live || !networks || networks.includes(networkName))
          .map(([name, { networks, overrides, interestRateModel, ...market }]) => {
            const config = {
              ...market,
              ...overrides?.[live ? networkName : Object.keys(overrides)[0]],
              interestRateModel: { ...finance.interestRateModel, ...interestRateModel },
            };
            if (config.rewards) {
              config.rewards = Object.fromEntries(
                Object.entries(config.rewards).map(([asset, rewards]) => [asset, { ...finance.rewards, ...rewards }]),
              );
            }
            return [name, config];
          }),
      ),
      periphery: finance.periphery?.[live ? networkName : Object.keys(finance.periphery)[0]],
    };
  }
});

declare module "hardhat/types/config" {
  export interface FinanceConfig {
    liquidationIncentive: { liquidator: number; lenders: number };
    penaltyRatePerDay: number;
    treasuryFeeRate?: number;
    backupFeeRate: number;
    reserveFactor: number;
    dampSpeed: { up: number; down: number };
    futurePools: number;
    earningsAccumulatorSmoothFactor: number;
    rewards: RewardsParameters;
    escrow: EscrowParameters;
    interestRateModel: IRMParameters;
    markets: { [asset: string]: MarketConfig };
    periphery: PeripheryConfig;
  }

  export interface FinanceUserConfig extends Omit<FinanceConfig, "markets" | "periphery" | "interestRateModel"> {
    markets: { [asset: string]: MarketUserConfig };
    periphery: { [network: string]: PeripheryConfig };
    interestRateModel: IRMParameters;
  }

  export interface RewardsParameters {
    undistributedFactor: number;
    flipSpeed: number;
    compensationFactor: number;
    transitionFactor: number;
    borrowAllocationWeightFactor: number;
    depositAllocationWeightAddend: number;
    depositAllocationWeightFactor: number;
  }

  export interface EscrowParameters {
    vestingPeriod: number;
    reserveRatio: number;
  }

  export interface MarketConfig {
    adjustFactor: number;
    priceFeed?: "double" | { wrapper: string; fn: string; baseUnit: bigint };
    interestRateModel: IRMParameters;
    rewards?: {
      [asset: string]: {
        total: number;
        debt: number;
        start: string;
        period: number;
      } & Partial<RewardsParameters>;
    };
  }

  export interface MarketUserConfig extends Omit<MarketConfig, "interestRateModel"> {
    networks?: string[];
    overrides?: { [network: string]: Partial<MarketUserConfig> };
    interestRateModel?: Partial<IRMParameters>;
  }

  export interface IRMParameters {
    minRate: number;
    naturalRate: number;
    maxUtilization: number;
    naturalUtilization: number;
    growthSpeed: number;
    sigmoidSpeed: number;
    spreadFactor: number;
    maturitySpeed: number;
    timePreference: number;
    fixedAllocation: number;
    maxRate: number;
  }

  export interface PeripheryConfig {
    extraReserve?: number;
    uniswapFees: { assets: [string, string]; fee: number }[];
  }

  export interface HardhatUserConfig {
    finance: FinanceUserConfig;
  }

  export interface HttpNetworkUserConfig {
    priceDecimals: number;
    timelockDelay?: number;
    finance?: Partial<FinanceConfig>;
  }

  export interface HardhatNetworkConfig {
    priceDecimals: number;
    timelockDelay: undefined;
    finance: FinanceConfig;
  }

  export interface HttpNetworkConfig {
    priceDecimals: number;
    timelockDelay?: number;
    finance: FinanceConfig;
  }
}
