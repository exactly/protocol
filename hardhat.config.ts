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
import { defaultHdAccountsConfigParams } from "hardhat/internal/core/config/default-config";
import type { HardhatUserConfig as Config } from "hardhat/types";

setup({ automaticVerifications: false });

export default {
  solidity: {
    version: "0.8.17",
    settings: { optimizer: { enabled: true, runs: 200 }, debug: { revertStrings: "strip" } },
  },
  networks: {
    mainnet: { priceDecimals: 18, timelockDelay: 24 * 3_600, url: env.MAINNET_NODE ?? "", finance: { futurePools: 3 } },
    optimism: { priceDecimals: 8, timelockDelay: 24 * 3_600, url: env.OPTIMISM_NODE ?? "", leverager: true },
    goerli: { priceDecimals: 8, url: env.GOERLI_NODE ?? "" },
  },
  namedAccounts: {
    deployer: {
      default: 0,
      mainnet: "0xe61Bdef3FFF4C3CF7A07996DCB8802b5C85B665a",
      optimism: "0xe61Bdef3FFF4C3CF7A07996DCB8802b5C85B665a",
      goerli: "0xDb90CDB64CfF03f254e4015C4F705C3F3C834400",
    },
    multisig: {
      default: 0,
      mainnet: "0x7A65824d74B0C20730B6eE4929ABcc41Cbe843Aa",
      optimism: "0xC0d6Bc5d052d1e74523AD79dD5A954276c9286D3",
      goerli: "0x1801f5EAeAbA3fD02cBF4b7ED1A7b58AD84C0705",
    },
  },
  finance: {
    liquidationIncentive: { liquidator: 0.05, lenders: 0.0025 },
    penaltyRatePerDay: 0.0045,
    backupFeeRate: 0.1,
    reserveFactor: 0.1,
    dampSpeed: { up: 0.0046, down: 0.4 },
    futurePools: 6,
    earningsAccumulatorSmoothFactor: 2,
    rewards: {
      undistributedFactor: 0.5,
      flipSpeed: 2,
      compensationFactor: 0.85,
      transitionFactor: 0.83,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02,
      depositAllocationWeightFactor: 0.01,
    },
    markets: {
      WETH: {
        adjustFactor: 0.84,
        floatingCurve: { a: 1.9362e-2, b: -1.787e-3, maxUtilization: 1.003870947 },
        fixedCurve: { a: 3.8126e-1, b: -3.6375e-1, maxUtilization: 1.000010695 },
        overrides: {
          goerli: {
            rewards: { OP: { total: 60_000, debt: 16_000, start: "2023-03-09", period: 8 * 7 * 86_400 } },
          },
          optimism: {
            rewards: {
              OP: {
                total: 60_000,
                debt: 1_666,
                start: "2023-04-03T14:00Z",
                period: 8 * 7 * 86_400,
                undistributedFactor: 0.3,
                compensationFactor: 0.7,
                transitionFactor: 0.7056,
                depositAllocationWeightAddend: 0.03,
              },
            },
          },
        },
      },
      DAI: {
        networks: ["mainnet", "goerli"],
        adjustFactor: 0.9,
        floatingCurve: { a: 1.7852e-2, b: -2.789e-3, maxUtilization: 1.003568501 },
        fixedCurve: { a: 3.9281e-1, b: -3.7781e-1, maxUtilization: 1.000014451 },
      },
      USDC: {
        adjustFactor: 0.91,
        floatingCurve: { a: 1.4844e-2, b: 1.9964e-4, maxUtilization: 1.002968978 },
        fixedCurve: { a: 3.9281e-1, b: -3.7781e-1, maxUtilization: 1.000014451 },
        overrides: {
          goerli: {
            rewards: { OP: { total: 140_000, debt: 25_000_000, start: "2023-03-09", period: 8 * 7 * 86_400 } },
          },
          optimism: {
            rewards: { OP: { total: 140_000, debt: 7_500_000, start: "2023-04-03T14:00Z", period: 8 * 7 * 86_400 } },
          },
        },
      },
      WBTC: {
        networks: ["mainnet", "goerli"],
        adjustFactor: 0.85,
        floatingCurve: { a: 3.6184e-2, b: -1.5925e-2, maxUtilization: 1.007213882 },
        fixedCurve: { a: 3.697e-1, b: -3.497e-1, maxUtilization: 1.000007768 },
        overrides: {
          mainnet: { priceFeed: "double" },
          goerli: { priceFeed: "double" },
        },
      },
      wstETH: {
        adjustFactor: 0.82,
        floatingCurve: { a: 1.9362e-2, b: -1.787e-3, maxUtilization: 1.003870947 },
        fixedCurve: { a: 3.8126e-1, b: -3.6375e-1, maxUtilization: 1.000010695 },
        priceFeed: { wrapper: "stETH", fn: "getPooledEthByShares", baseUnit: 10n ** 18n },
        overrides: {
          optimism: { adjustFactor: 0.8, priceFeed: undefined },
        },
      },
      OP: {
        networks: ["optimism"],
        adjustFactor: 0.58,
        floatingCurve: { a: 2.8487e-2, b: -5.8259e-3, maxUtilization: 1.005690787 },
        fixedCurve: { a: 3.5815e-1, b: -3.3564e-1, maxUtilization: 1.000005527 },
      },
    },
  },
  dodoc: { exclude: ["mocks/", "k/", "elin/", "rc/"] },
  tenderly: { project: "exactly", username: "exactly", privateVerification: false },
  typechain: { outDir: "types", target: "ethers-v5" },
  contractSizer: { runOnCompile: true, only: ["^contracts/"], except: ["mocks"] },
  gasReporter: { currency: "USD", gasPrice: 100, enabled: !!JSON.parse(env.REPORT_GAS ?? "false") },
} as Config;

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

extendConfig((hardhatConfig, { finance }) => {
  delete (hardhatConfig as any).finance; // eslint-disable-line @typescript-eslint/no-explicit-any
  for (const [networkName, networkConfig] of Object.entries(hardhatConfig.networks)) {
    const live = !["hardhat", "localhost"].includes(networkName);
    if (live) {
      networkConfig.safeTxService = `https://safe-transaction-${networkName}.safe.global`;
      if (env.MNEMONIC) networkConfig.accounts = { ...defaultHdAccountsConfigParams, mnemonic: env.MNEMONIC };
    } else Object.assign(networkConfig, { priceDecimals: 8, allowUnlimitedContractSize: true, leverager: true });
    networkConfig.finance = {
      ...finance,
      ...networkConfig.finance,
      markets: Object.fromEntries(
        Object.entries(finance.markets)
          .filter(([, { networks }]) => !live || !networks || networks.includes(networkName))
          .map(([name, { networks, overrides, ...market }]) => {
            const config = { ...market, ...overrides?.[live ? networkName : Object.keys(overrides)[0]] };
            if (config.rewards) {
              config.rewards = Object.fromEntries(
                Object.entries(config.rewards).map(([asset, rewards]) => [asset, { ...finance.rewards, ...rewards }]),
              );
            }
            return [name, config];
          }),
      ),
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
    markets: { [asset: string]: MarketUserConfig };
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

  export interface MarketConfig {
    adjustFactor: number;
    fixedCurve: Curve;
    floatingCurve: Curve;
    priceFeed?: "double" | { wrapper: string; fn: string; baseUnit: bigint };
    rewards?: {
      [asset: string]: {
        total: number;
        debt: number;
        start: string;
        period: number;
      } & Partial<RewardsParameters>;
    };
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

  export interface HardhatUserConfig {
    finance: FinanceConfig;
  }

  export interface HttpNetworkUserConfig {
    priceDecimals: number;
    timelockDelay?: number;
    leverager?: boolean;
    finance?: Partial<FinanceConfig>;
  }

  export interface HardhatNetworkConfig {
    priceDecimals: number;
    timelockDelay: undefined;
    leverager: boolean;
    safeTxService: undefined;
    finance: FinanceConfig;
  }

  export interface HttpNetworkConfig {
    priceDecimals: number;
    timelockDelay?: number;
    leverager?: boolean;
    safeTxService: string;
    finance: FinanceConfig;
  }
}
