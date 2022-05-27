import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import { BigNumber } from "ethers";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { FixedLender, MockInterestRateModel, MockToken, Auditor, MockChainlinkFeedRegistry } from "../types";
import futurePools, { INTERVAL } from "./utils/futurePools";
import timelockExecute from "./utils/timelockExecute";

const {
  utils: { parseUnits },
  getUnnamedSigners,
  getNamedSigner,
  getContract,
} = ethers;

describe("Smart Pool Earnings Distribution", function () {
  let dai: MockToken;
  let wbtc: MockToken;
  let fixedLenderDAI: FixedLender;
  let fixedLenderWBTC: FixedLender;
  let feedRegistry: MockChainlinkFeedRegistry;
  let auditor: Auditor;
  let irm: MockInterestRateModel;

  let owner: SignerWithAddress;
  let bob: SignerWithAddress;
  let john: SignerWithAddress;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [bob, john] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture(["Markets"]);

    dai = await getContract<MockToken>("DAI", bob);
    wbtc = await getContract<MockToken>("WBTC", bob);
    fixedLenderDAI = await getContract<FixedLender>("FixedLenderDAI", bob);
    fixedLenderWBTC = await getContract<FixedLender>("FixedLenderWBTC", bob);
    feedRegistry = await getContract<MockChainlinkFeedRegistry>("FeedRegistry", bob);
    auditor = await getContract<Auditor>("Auditor", bob);

    await deployments.deploy("MockInterestRateModel", { args: [0], from: owner.address });
    irm = await getContract<MockInterestRateModel>("MockInterestRateModel", bob);
    await timelockExecute(owner, fixedLenderDAI, "setInterestRateModel", [irm.address]);
    await irm.setBorrowRate(parseUnits("0.1"));

    for (const signer of [bob, john]) {
      await dai.connect(owner).transfer(signer.address, parseUnits("50000"));
      await dai.connect(signer).approve(fixedLenderDAI.address, parseUnits("50000"));
      await wbtc.connect(owner).transfer(signer.address, parseUnits("1", 8));
      await wbtc.connect(signer).approve(fixedLenderWBTC.address, parseUnits("1", 8));
    }
  });

  describe("GIVEN bob deposits 10k and borrows 1k from a 28 day mp, AND john deposits 10k at half maturity time", () => {
    beforeEach(async () => {
      await fixedLenderDAI.deposit(parseUnits("10000"), bob.address);

      await feedRegistry.setUpdatedAtTimestamp(futurePools(1)[0].toNumber());
      await ethers.provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber()]);

      await fixedLenderDAI.borrowAtMaturity(
        futurePools(1)[0].add(INTERVAL),
        parseUnits("1000"),
        parseUnits("1100"),
        bob.address,
        bob.address,
      );

      await ethers.provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + INTERVAL / 2]);
      await fixedLenderDAI.connect(john).deposit(parseUnits("10000"), john.address);
    });
    it("THEN bob eToken shares is 10000", async () => {
      expect(await fixedLenderDAI.balanceOf(bob.address)).to.equal(parseUnits("10000"));
    });
    it("THEN john eToken shares is aprox. 9950", async () => {
      // 10000 * 10000 / 10050 (50 earnings up to half maturity time)
      // assets.mulDivDown(supply, totalAssets())
      expect(await fixedLenderDAI.balanceOf(john.address)).to.closeTo(
        parseUnits("9950.24875621"),
        parseUnits("0000.00000001").toNumber(),
      );
    });
    it("THEN preview deposit returned is the same as john's shares of tokens", async () => {
      // 10000 * 19950.24875621 / 20050
      // assets.mulDivDown(supply, totalAssets())
      expect(await fixedLenderDAI.previewDeposit(parseUnits("10000"))).to.closeTo(
        parseUnits("9950.24875621"),
        parseUnits("0000.00000001").toNumber(),
      );
    });
    it("THEN the smart pool earnings accumulator did not account any earnings", async () => {
      expect(await fixedLenderDAI.smartPoolEarningsAccumulator()).to.be.eq(0);
    });
    describe("AND GIVEN 7 days go by and bob repays late", () => {
      beforeEach(async () => {
        await feedRegistry.setUpdatedAtTimestamp(futurePools(1)[0].toNumber() + INTERVAL + 86_400 * 7);
        // 7 * 0,02 -> 14% late repayments (154)
        await ethers.provider.send("evm_setNextBlockTimestamp", [
          futurePools(1)[0].toNumber() + INTERVAL + 86_400 * 7 + 1,
        ]);
        await fixedLenderDAI.repayAtMaturity(
          futurePools(1)[0].add(INTERVAL),
          parseUnits("1254"),
          parseUnits("1255"),
          bob.address,
        );
      });
      it("THEN the smart pool earnings accumulator has balance", async () => {
        expect(await fixedLenderDAI.smartPoolEarningsAccumulator()).to.be.gt(parseUnits("154"));
        expect(await fixedLenderDAI.smartPoolEarningsAccumulator()).to.be.lt(parseUnits("154.1"));
      });
      it("THEN preview deposit returned is less than previous deposits since depositing will first accrue earnings", async () => {
        expect(await fixedLenderDAI.previewDeposit(parseUnits("10000"))).to.be.lt(parseUnits("9950.24875621"));
      });
      describe("AND GIVEN accumulator factor is set to 0 AND bob & john preview withdraw all their assets", () => {
        let assetsInFixedLender: BigNumber;
        let assetsToBeWithdrawn: BigNumber;
        beforeEach(async () => {
          assetsInFixedLender = await dai.balanceOf(fixedLenderDAI.address);

          await timelockExecute(owner, fixedLenderDAI, "setAccumulatedEarningsSmoothFactor", [0]);
          const assetsBob = await fixedLenderDAI.previewRedeem(await fixedLenderDAI.balanceOf(bob.address));
          const assetsJohn = await fixedLenderDAI
            .connect(john)
            .previewRedeem(await fixedLenderDAI.balanceOf(john.address));

          assetsToBeWithdrawn = assetsBob.add(assetsJohn);
        });
        it("THEN the previous fixed lender DAI balance is equal to the total assets to be withdrawn", async () => {
          expect(assetsInFixedLender).to.be.closeTo(assetsToBeWithdrawn, 1);
          expect((await dai.balanceOf(fixedLenderDAI.address)).sub(assetsToBeWithdrawn)).to.eq(1);
        });
        it("THEN the maturity used is also empty", async () => {
          expect((await fixedLenderDAI.maturityPools(futurePools(1)[0].add(INTERVAL))).earningsUnassigned).to.be.eq(0);
        });
      });
      describe("AND GIVEN accumulator factor is not set to 0 AND bob & john withdraw all their assets", () => {
        beforeEach(async () => {
          await fixedLenderDAI.redeem(await fixedLenderDAI.balanceOf(bob.address), bob.address, bob.address);
          await fixedLenderDAI
            .connect(john)
            .redeem(await fixedLenderDAI.balanceOf(john.address), john.address, john.address);
        });
        it("THEN the fixed lender DAI balance is equal to the accumulator counter", async () => {
          expect(await dai.balanceOf(fixedLenderDAI.address)).to.be.eq(
            await fixedLenderDAI.smartPoolEarningsAccumulator(),
          );
        });
        describe("AND GIVEN bob deposits 10k again", () => {
          let accumulatorBefore: BigNumber;
          beforeEach(async () => {
            accumulatorBefore = await fixedLenderDAI.smartPoolEarningsAccumulator();
            await expect(fixedLenderDAI.deposit(parseUnits("10000"), bob.address)).to.not.be.reverted;
          });
          it("THEN he accrues earnings of the accumulator since he is the only deposit", async () => {
            expect(await fixedLenderDAI.previewRedeem(await fixedLenderDAI.balanceOf(bob.address))).to.be.gt(
              parseUnits("10000"),
            );
          });
          it("THEN the accumulator is correctly updated", async () => {
            const bobAssetBalance = await fixedLenderDAI.previewRedeem(await fixedLenderDAI.balanceOf(bob.address));
            expect(await fixedLenderDAI.smartPoolEarningsAccumulator()).to.be.eq(
              accumulatorBefore.sub(bobAssetBalance).add(parseUnits("10000")),
            );
          });
        });
      });
    });
    describe("AND GIVEN john deposits again 1k at day 20 (8 days until maturity)", () => {
      beforeEach(async () => {
        await ethers.provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + INTERVAL - 86_400 * 8]);
        await fixedLenderDAI.connect(john).deposit(parseUnits("1000"), john.address);
      });
      it("THEN john eToken shares is aprox. 10944", async () => {
        // 9950.24875621 + 1000 * 19950.24875621 / 20071.42 (71.42 earnings up to day 5)
        // previousTokens + assets.mulDivDown(supply, totalAssets())
        expect(await fixedLenderDAI.balanceOf(john.address)).to.closeTo(
          parseUnits("10944.2113277"),
          parseUnits("00000.0000001").toNumber(),
        );
      });
      describe("AND GIVEN john deposits another 1k at maturity date", () => {
        beforeEach(async () => {
          await ethers.provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + INTERVAL]);
          await fixedLenderDAI.connect(john).deposit(parseUnits("1000"), john.address);
        });
        it("THEN john eToken shares is aprox. 10944", async () => {
          // 10944.2113277 + 1000 * 20944.2113277 / 21100
          // previousTokens + assets.mulDivDown(supply, totalAssets())
          expect(await fixedLenderDAI.balanceOf(john.address)).to.closeTo(
            parseUnits("11936.8279783"),
            parseUnits("00000.0000001").toNumber(),
          );
        });
      });
    });
  });
  describe("GIVEN bob has plenty of WBTC collateral", () => {
    beforeEach(async () => {
      await fixedLenderWBTC.deposit(parseUnits("1", 8), bob.address);
      await auditor.enterMarkets([fixedLenderWBTC.address]);
    });
    describe("GIVEN bob deposits 10k and borrows 10k from a mp", () => {
      beforeEach(async () => {
        await fixedLenderDAI.deposit(parseUnits("10000"), bob.address);
        await timelockExecute(owner, fixedLenderDAI, "setSmartPoolReserveFactor", [0]);

        await feedRegistry.setUpdatedAtTimestamp(futurePools(1)[0].toNumber());
        await ethers.provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber()]);
        await fixedLenderDAI.borrowAtMaturity(
          futurePools(1)[0].add(INTERVAL),
          parseUnits("10000"),
          parseUnits("11000"),
          bob.address,
          bob.address,
        );
      });
      describe("AND GIVEN john deposits 10k after maturity date", () => {
        beforeEach(async () => {
          await ethers.provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + INTERVAL]);
          await fixedLenderDAI.connect(john).deposit(parseUnits("10000"), john.address);
        });
        it("THEN john eToken balance should be less than 10000", async () => {
          expect(await fixedLenderDAI.balanceOf(john.address)).to.be.lt(parseUnits("10000"));
        });
      });
    });
  });
});
