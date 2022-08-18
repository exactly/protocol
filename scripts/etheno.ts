import { ethers, network, run } from "hardhat";
import { TASK_DEPLOY_RUN_DEPLOY } from "hardhat-deploy";
import type { ContractTransaction } from "ethers";
import type { Auditor, Market, MockERC20, MockPriceFeed } from "../types";
import futurePools, { INTERVAL } from "../test/utils/futurePools";

if (network.live) throw new Error("wrong network");

const {
  constants: { MaxUint256 },
  getContract,
  getSigners,
  provider,
} = ethers;

run(TASK_DEPLOY_RUN_DEPLOY, { reset: true, tags: "Markets" })
  .then(async () => {
    const [signers, marketDAI, marketWBTC, auditor, dai, wbtc, priceFeedWBTC] = await Promise.all([
      getSigners(),
      getContract<Market>("MarketDAI"),
      getContract<Market>("MarketWBTC"),
      getContract<Auditor>("Auditor"),
      getContract<MockERC20>("DAI"),
      getContract<MockERC20>("WBTC"),
      getContract<MockPriceFeed>("PriceFeedWBTC"),
    ]);

    for (const signer of signers) {
      await tx(dai.connect(signer).approve(marketDAI.address, MaxUint256, overrides));
      await tx(wbtc.connect(signer).approve(marketWBTC.address, MaxUint256, overrides));
      await tx(dai.connect(signer).mint(signer.address, MaxUint256.div(1_000), overrides));
      await tx(wbtc.connect(signer).mint(signer.address, MaxUint256.div(1_000), overrides));
      await tx(auditor.connect(signer).enterMarket(marketDAI.address, overrides));
      await tx(auditor.connect(signer).enterMarket(marketWBTC.address, overrides));
    }

    const [decimalsDAI, decimalsWBTC, maxFuturePools, { timestamp }] = await Promise.all([
      dai.decimals(),
      wbtc.decimals(),
      marketDAI.maxFuturePools(),
      provider.getBlock("latest"),
    ]);

    await tx(marketDAI.deposit(666_666_666n * 10n ** BigInt(decimalsDAI), signers[0].address, overrides));
    await provider.send("evm_increaseTime", [9011]);

    for (const [i, signer] of signers.entries()) {
      await tx(
        marketWBTC.connect(signer).deposit(BigInt(i + 1) * 10n ** BigInt(decimalsWBTC), signer.address, overrides),
      );

      for (const maturity of futurePools(maxFuturePools, INTERVAL, timestamp)) {
        await tx(
          marketDAI
            .connect(signer)
            .borrowAtMaturity(
              maturity,
              BigInt(i + 1) * 10_000n * 10n ** BigInt(decimalsDAI),
              MaxUint256,
              signer.address,
              signer.address,
              overrides,
            ),
        );
      }
    }

    await tx(priceFeedWBTC.setPrice(50_000n * 10n ** BigInt(decimalsWBTC), overrides));
  })
  .catch((error) => {
    throw error;
  });

const tx = async (txPromise: Promise<ContractTransaction>) => (await txPromise).wait();
const overrides = { gasLimit: 666_666 };
