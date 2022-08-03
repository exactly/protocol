import "dotenv/config";
import "hardhat-deploy";
import "solidity-coverage";
import "@typechain/hardhat";
import "hardhat-gas-reporter";
import "@nomiclabs/hardhat-waffle";
import "@primitivefi/hardhat-dodoc";
import "@openzeppelin/hardhat-upgrades";
import { env } from "process";
import { task } from "hardhat/config";
import { boolean, string } from "hardhat/internal/core/params/argumentTypes";
import type { HardhatUserConfig as Config } from "hardhat/types";

const config: Config = {
  solidity: { version: "0.8.15", settings: { optimizer: { enabled: true, runs: 200 } } },
  networks: {
    hardhat: {
      accounts: { accountsBalance: `1${"0".repeat(32)}` },
      allowUnlimitedContractSize: true,
    },
    rinkeby: {
      gnosisSafeTxService: "https://safe-transaction.rinkeby.gnosis.io/",
      url: env.RINKEBY_NODE ?? "https://rinkeby.infura.io/",
      ...(env.MNEMONIC && { accounts: { mnemonic: env.MNEMONIC } }),
    },
  },
  namedAccounts: {
    deployer: { default: 0 },
    multisig: {
      default: 1,
      rinkeby: "0x755DF607BA55ff6430FEE0126A52Bf82D1e57F5f",
    },
  },
  finance: {
    assets: ["DAI", "WETH", "USDC", "WBTC"],
    adjustFactor: { default: 0.8, WBTC: 0.6 },
    liquidationIncentive: {
      liquidator: 0.05,
      lenders: 0.01,
    },
    penaltyRatePerDay: 0.02,
    backupFeeRate: 0.1,
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
  export interface Curve {
    a: number;
    b: number;
    maxUtilization: number;
  }
  export interface FinanceConfig {
    assets: string[];
    adjustFactor: { default: number; [asset: string]: number };
    liquidationIncentive: { liquidator: number; lenders: number };
    penaltyRatePerDay: number;
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
      fixedFullUtilization: number;
      floatingCurve: Curve;
      floatingFullUtilization: number;
    };
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
