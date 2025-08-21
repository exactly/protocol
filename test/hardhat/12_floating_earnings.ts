import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { Auditor, Market, MockERC20, MockBorrowRate } from "../../types";
import futurePools, { INTERVAL } from "./utils/futurePools";
import timelockExecute from "./utils/timelockExecute";

const { ZeroAddress, parseUnits, getUnnamedSigners, getNamedSigner, getContract, provider } = ethers;

describe("Smart Pool Earnings Distribution", function () {
  let dai: MockERC20;
  let wbtc: MockERC20;
  let marketDAI: Market;
  let marketWBTC: Market;
  let auditor: Auditor;
  let irm: MockBorrowRate;

  let owner: SignerWithAddress;
  let bob: SignerWithAddress;
  let john: SignerWithAddress;
  let pools: number[];

  before(async () => {
    owner = await getNamedSigner("multisig");
    [bob, john] = await getUnnamedSigners();
    pools = await futurePools(1);
  });

  beforeEach(async () => {
    await deployments.fixture("Markets");

    dai = await getContract<MockERC20>("DAI", bob);
    wbtc = await getContract<MockERC20>("WBTC", bob);
    auditor = await getContract<Auditor>("Auditor", bob);
    marketDAI = await getContract<Market>("MarketDAI", bob);
    marketWBTC = await getContract<Market>("MarketWBTC", bob);

    await deployments.deploy("MockBorrowRate", { args: [0], from: owner.address });
    irm = await getContract<MockBorrowRate>("MockBorrowRate", bob);
    await timelockExecute(owner, marketDAI, "setInterestRateModel", [irm.target]);
    await timelockExecute(owner, marketDAI, "setTreasury", [ZeroAddress, 0]);
    await irm.setRate(parseUnits("0.1"));

    for (const signer of [bob, john]) {
      await dai.connect(owner).mint(signer.address, parseUnits("50000"));
      await dai.connect(signer).approve(marketDAI.target, parseUnits("50000"));
      await wbtc.connect(owner).mint(signer.address, parseUnits("1", 8));
      await wbtc.connect(signer).approve(marketWBTC.target, parseUnits("1", 8));
    }
  });

  describe("GIVEN bob deposits 10k and borrows 1k from a 28 day mp, AND john deposits 10k at half maturity time", () => {
    beforeEach(async () => {
      await marketDAI.deposit(parseUnits("10000"), bob.address);

      await provider.send("evm_setNextBlockTimestamp", [pools[0]]);

      await marketDAI.borrowAtMaturity(
        pools[0] + INTERVAL,
        parseUnits("1000"),
        parseUnits("1100"),
        bob.address,
        bob.address,
      );

      await provider.send("evm_setNextBlockTimestamp", [pools[0] + INTERVAL / 2]);
      await marketDAI.connect(john).deposit(parseUnits("10000"), john.address);
    });

    it("THEN bob eToken shares is 10000", async () => {
      expect(await marketDAI.balanceOf(bob.address)).to.equal(parseUnits("10000"));
    });

    it("THEN john eToken shares is aprox. 9950", async () => {
      // 10000 * 10000 / 10050 (50 earnings up to half maturity time)
      // assets.mulDivDown(supply, totalAssets())
      expect(await marketDAI.balanceOf(john.address)).to.closeTo(
        parseUnits("9950.24875621"),
        parseUnits("0000.00000001"),
      );
    });

    it("THEN preview deposit returned is the same as john's shares of assets", async () => {
      // 10000 * 19950.24875621 / 20050
      // assets.mulDivDown(supply, totalAssets())
      expect(await marketDAI.previewDeposit(parseUnits("10000"))).to.closeTo(
        parseUnits("9950.24875621"),
        parseUnits("0000.00000001"),
      );
    });

    it("THEN the smart pool earnings accumulator did not account any earnings", async () => {
      expect(await marketDAI.earningsAccumulator()).to.be.eq(0);
    });

    describe("AND GIVEN 7 days go by and bob repays late", () => {
      beforeEach(async () => {
        await provider.send("evm_setNextBlockTimestamp", [pools[0] + INTERVAL + 86_400 * 7 + 1]);
        await marketDAI.repayAtMaturity(pools[0] + INTERVAL, parseUnits("1254"), parseUnits("1255"), bob.address);
      });

      it("THEN the smart pool earnings accumulator has balance", async () => {
        let penaltyRate = await marketDAI.penaltyRate();
        penaltyRate = penaltyRate * 86_400n * 7n;
        expect(await marketDAI.earningsAccumulator()).to.be.gt((parseUnits("1100") * penaltyRate) / parseUnits("1"));
        expect(await marketDAI.earningsAccumulator()).to.be.lt((parseUnits("1100.01") * penaltyRate) / parseUnits("1"));
      });

      it("THEN preview deposit returned is less than previous deposits since depositing will first accrue earnings", async () => {
        expect(await marketDAI.previewDeposit(parseUnits("10000"))).to.be.lt(parseUnits("9950.24875621"));
      });

      describe("AND GIVEN accumulator factor is not updated AND bob & john withdraw all their assets", () => {
        beforeEach(async () => {
          await marketDAI.redeem(await marketDAI.balanceOf(bob.address), bob.address, bob.address);
          await marketDAI.connect(john).redeem(await marketDAI.balanceOf(john.address), john.address, john.address);
        });

        it("THEN the market DAI balance is equal to the accumulator counter", async () => {
          expect(await dai.balanceOf(marketDAI.target)).to.be.eq(await marketDAI.earningsAccumulator());
        });

        describe("AND GIVEN bob deposits 10k again", () => {
          let accumulatorBefore: bigint;

          beforeEach(async () => {
            accumulatorBefore = await marketDAI.earningsAccumulator();
            await expect(marketDAI.deposit(parseUnits("10000"), bob.address)).to.not.be.reverted;
          });

          it("THEN he accrues earnings of the accumulator since he is the only deposit", async () => {
            expect(await marketDAI.previewRedeem(await marketDAI.balanceOf(bob.address))).to.be.gt(parseUnits("10000"));
          });

          it("THEN the accumulator is correctly updated", async () => {
            const bobAssetBalance = await marketDAI.previewRedeem(await marketDAI.balanceOf(bob.address));
            expect(await marketDAI.earningsAccumulator()).to.be.eq(
              accumulatorBefore - bobAssetBalance + parseUnits("10000"),
            );
          });
        });
      });
    });

    describe("AND GIVEN john deposits again 1k at day 20 (8 days until maturity)", () => {
      beforeEach(async () => {
        await provider.send("evm_setNextBlockTimestamp", [pools[0] + INTERVAL - 86_400 * 8]);
        await marketDAI.connect(john).deposit(parseUnits("1000"), john.address);
      });

      it("THEN john eToken shares is aprox. 10944", async () => {
        // 9950.24875621 + 1000 * 19950.24875621 / 20071.42 (71.42 earnings up to day 5)
        // previousAssets + assets.mulDivDown(supply, totalAssets())
        expect(await marketDAI.balanceOf(john.address)).to.closeTo(
          parseUnits("10944.2113277"),
          parseUnits("00000.0000001"),
        );
      });

      describe("AND GIVEN john deposits another 1k at maturity date", () => {
        beforeEach(async () => {
          await provider.send("evm_setNextBlockTimestamp", [pools[0] + INTERVAL]);
          await marketDAI.connect(john).deposit(parseUnits("1000"), john.address);
        });

        it("THEN john eToken shares is aprox. 10944", async () => {
          // 10944.2113277 + 1000 * 20944.2113277 / 21100
          // previousAssets + assets.mulDivDown(supply, totalAssets())
          expect(await marketDAI.balanceOf(john.address)).to.closeTo(
            parseUnits("11936.8279783"),
            parseUnits("00000.0000001"),
          );
        });
      });
    });
  });

  describe("GIVEN bob has plenty of WBTC collateral", () => {
    beforeEach(async () => {
      await marketWBTC.deposit(parseUnits("1", 8), bob.address);
      await auditor.enterMarket(marketWBTC.target);
    });

    describe("GIVEN bob deposits 10k and borrows 10k from a mp", () => {
      beforeEach(async () => {
        await marketDAI.deposit(parseUnits("10000"), bob.address);
        await timelockExecute(owner, marketDAI, "setReserveFactor", [0]);

        await provider.send("evm_setNextBlockTimestamp", [pools[0]]);
        await marketDAI.borrowAtMaturity(
          pools[0] + INTERVAL,
          parseUnits("10000"),
          parseUnits("11000"),
          bob.address,
          bob.address,
        );
      });

      describe("AND GIVEN john deposits 10k after maturity date", () => {
        beforeEach(async () => {
          await provider.send("evm_setNextBlockTimestamp", [pools[0] + INTERVAL]);
          await marketDAI.connect(john).deposit(parseUnits("10000"), john.address);
        });

        it("THEN john eToken balance should be less than 10000", async () => {
          expect(await marketDAI.balanceOf(john.address)).to.be.lt(parseUnits("10000"));
        });
      });
    });
  });
});
