import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { Auditor, Market, MockERC20, WETH } from "../../types";
import timelockExecute from "./utils/timelockExecute";
import futurePools from "./utils/futurePools";

const { ZeroAddress, parseUnits, getUnnamedSigners, getNamedSigner, getContract, provider } = ethers;
const { deploy, fixture } = deployments;

describe("Liquidity computations", function () {
  let dai: MockERC20;
  let usdc: MockERC20;
  let wbtc: MockERC20;
  let weth: WETH;
  let auditor: Auditor;
  let marketDAI: Market;
  let marketUSDC: Market;
  let marketWBTC: Market;
  let marketWETH: Market;

  let bob: SignerWithAddress;
  let laura: SignerWithAddress;
  let multisig: SignerWithAddress;
  let pools: number[];

  before(async () => {
    multisig = await getNamedSigner("multisig");
    [bob, laura] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await fixture("Markets");

    dai = await getContract<MockERC20>("DAI", laura);
    usdc = await getContract<MockERC20>("USDC.e", laura);
    wbtc = await getContract<MockERC20>("WBTC", laura);
    weth = await getContract<WETH>("WETH", laura);
    auditor = await getContract<Auditor>("Auditor", laura);
    marketDAI = await getContract<Market>("MarketDAI", laura);
    marketUSDC = await getContract<Market>("MarketUSDC.e", laura);
    marketWBTC = await getContract<Market>("MarketWBTC", laura);
    marketWETH = await getContract<Market>("MarketWETH", laura);
    pools = await futurePools(1);

    for (const signer of [bob, laura]) {
      for (const [underlying, market, decimals = 18] of [
        [dai, marketDAI],
        [usdc, marketUSDC, 6],
        [wbtc, marketWBTC, 8],
      ] as [MockERC20, Market, number?][]) {
        await underlying.connect(multisig).mint(signer.address, parseUnits("100000", decimals));
        await underlying.connect(signer).approve(market.target, parseUnits("100000", decimals));
      }
      await weth.deposit({ value: parseUnits("10") });
      await weth.approve(marketWETH.target, parseUnits("10"));
      await auditor.connect(signer).enterMarket(marketDAI.target);
      await auditor.connect(signer).enterMarket(marketUSDC.target);
      await auditor.connect(signer).enterMarket(marketWBTC.target);
    }

    const { address: irm } = await deploy("MockInterestRateModel", { args: [0], from: bob.address });
    await timelockExecute(multisig, marketDAI, "setInterestRateModel", [irm]);
    await timelockExecute(multisig, marketUSDC, "setInterestRateModel", [irm]);
    await timelockExecute(multisig, marketWBTC, "setInterestRateModel", [irm]);
    await timelockExecute(multisig, marketWETH, "setInterestRateModel", [irm]);

    await timelockExecute(multisig, auditor, "setAdjustFactor", [marketDAI.target, parseUnits("0.8")]);
    await timelockExecute(multisig, auditor, "setAdjustFactor", [marketUSDC.target, parseUnits("0.8")]);
    await timelockExecute(multisig, auditor, "setAdjustFactor", [marketWETH.target, parseUnits("0.8")]);
    await timelockExecute(multisig, auditor, "setAdjustFactor", [marketWBTC.target, parseUnits("0.6")]);
  });

  describe("positions aren't immediately liquidatable", () => {
    describe("GIVEN laura deposits 1k dai to a smart pool", () => {
      beforeEach(async () => {
        await marketDAI.deposit(parseUnits("1000"), laura.address);
        await provider.send("evm_increaseTime", [9_011]);
      });

      it("THEN lauras liquidity is adjustFactor*collateral -  0.8*1000 == 800, AND she has no shortfall", async () => {
        const [collateral, debt] = await auditor.accountLiquidity(laura.address, ZeroAddress, 0);

        expect(collateral).to.equal(parseUnits("800"));
        expect(debt).to.equal(parseUnits("0"));
      });
      // TODO: a test where the supply interest is != 0, see if there's an error like the one described in this commit
      it("AND she has zero debt and is owed 1000DAI", async () => {
        const [supplied, owed] = await marketDAI.accountSnapshot(laura.address);
        expect(supplied).to.equal(parseUnits("1000"));
        expect(owed).to.equal(parseUnits("0"));
      });

      describe("AND GIVEN a 1% borrow interest rate", () => {
        beforeEach(async () => {
          const { address: irm } = await deploy("MockInterestRateModel", {
            args: [parseUnits("0.01")],
            from: bob.address,
          });
          await timelockExecute(multisig, marketDAI, "setInterestRateModel", [irm]);
          await timelockExecute(multisig, marketUSDC, "setInterestRateModel", [irm]);
          await timelockExecute(multisig, marketWBTC, "setInterestRateModel", [irm]);
          await timelockExecute(multisig, marketWETH, "setInterestRateModel", [irm]);
          // add liquidity to the maturity
          await marketDAI.depositAtMaturity(pools[0], parseUnits("800"), parseUnits("800"), laura.address);
        });

        it("AND WHEN laura asks for a 800 DAI loan, THEN it reverts because the interests make the owed amount larger than liquidity", async () => {
          await expect(
            marketDAI.borrowAtMaturity(pools[0], parseUnits("800"), parseUnits("1000"), laura.address, laura.address),
          ).to.be.revertedWithCustomError(auditor, "InsufficientAccountLiquidity");
        });
      });

      describe("AND WHEN laura asks for a 640 DAI loan (640 / 0.8 = 800)", () => {
        beforeEach(async () => {
          // add liquidity to the maturity
          await marketDAI.depositAtMaturity(pools[0], parseUnits("640"), parseUnits("640"), laura.address);
          await marketDAI.borrowAtMaturity(
            pools[0],
            parseUnits("640"),
            parseUnits("800"),
            laura.address,
            laura.address,
          );
        });

        it("THEN lauras liquidity is zero, AND she has no shortfall", async () => {
          const [collateral, debt] = await auditor.accountLiquidity(laura.address, ZeroAddress, 0);
          expect(collateral).to.equal(debt);
        });

        it("AND she has 640 debt and is owed 1000DAI", async () => {
          const [supplied, borrowed] = await marketDAI.accountSnapshot(laura.address);

          expect(supplied).to.equal(parseUnits("1000"));
          expect(borrowed).to.equal(parseUnits("640"));
        });

        it("AND WHEN laura tries to exit her collateral DAI market it reverts since there's unpaid debt", async () => {
          await expect(auditor.exitMarket(marketDAI.target)).to.be.revertedWithCustomError(auditor, "RemainingDebt");
        });

        it("AND WHEN laura repays her debt THEN it does not revert when she tries to exit her collateral DAI market", async () => {
          await marketDAI.repayAtMaturity(pools[0], parseUnits("640"), parseUnits("640"), laura.address);
          await expect(auditor.exitMarket(marketDAI.target)).to.not.be.reverted;
        });

        describe("AND GIVEN laura deposits more collateral for another asset", () => {
          beforeEach(async () => {
            await marketWETH.depositAtMaturity(pools[0], parseUnits("1"), parseUnits("1"), laura.address);
            await auditor.enterMarket(marketWETH.target);
          });

          it("THEN it does not revert when she tries to exit her collateral ETH market", async () => {
            await expect(auditor.exitMarket(marketWETH.target)).to.not.be.reverted;
          });

          it("THEN it reverts when she tries to exit her collateral DAI market since it's the same that she borrowed from", async () => {
            await expect(auditor.exitMarket(marketDAI.target)).to.be.revertedWithCustomError(auditor, "RemainingDebt");
          });
        });
      });
    });
  });

  describe("unpaid debts after maturity", () => {
    describe("GIVEN a well funded maturity pool (10k dai, laura), AND collateral for the borrower, (10k usdc, bob)", () => {
      beforeEach(async () => {
        await marketDAI.depositAtMaturity(pools[0], parseUnits("10000"), parseUnits("10000"), laura.address);
        await marketUSDC.connect(bob).deposit(parseUnits("10000", 6), bob.address);
      });

      describe("WHEN bob asks for a 5600 dai loan (10k usdc should give him 6400 DAI liquidity)", () => {
        beforeEach(async () => {
          await marketDAI
            .connect(bob)
            .borrowAtMaturity(pools[0], parseUnits("5600"), parseUnits("5600"), bob.address, bob.address);
        });

        it("THEN bob has 1k usd liquidity and no shortfall", async () => {
          const [collateral, debt] = await auditor.accountLiquidity(bob.address, ZeroAddress, 0);
          expect(collateral - debt).to.equal(parseUnits("1000"));
        });

        describe("AND WHEN moving to five days after the maturity date", () => {
          beforeEach(async () => {
            // Move in time to maturity
            await provider.send("evm_setNextBlockTimestamp", [pools[0] + 86_400 * 5]);
          });

          it("THEN 5 days of *daily* base rate interest is charged, adding 0.02*5 =10% interest to the debt", async () => {
            await provider.send("evm_mine", []);
            const [collateral, debt] = await auditor.accountLiquidity(bob.address, ZeroAddress, 0);
            // based on the events emitted, calculate the liquidity
            // need to take into account the fixed rates that the borrow and the lent got at the time of the transaction
            const totalSupplyAmount = parseUnits("10000");
            const totalBorrowAmount = parseUnits("5400");
            const calculatedLiquidity = totalSupplyAmount - (totalBorrowAmount * 2n * 5n) / 100n; // 2% * 5 days
            // TODO: this should equal
            expect(collateral - debt).to.be.lt(calculatedLiquidity);
          });

          describe("AND WHEN moving to fifteen days after the maturity date", () => {
            beforeEach(async () => {
              // Move in time to maturity
              await provider.send("evm_setNextBlockTimestamp", [pools[0] + 86_400 * 15]);
            });

            it("THEN 15 days of *daily* base rate interest is charged, adding 0.02*15 =35% interest to the debt, causing a shortfall", async () => {
              await provider.send("evm_mine", []);
              const [collateral, debt] = await auditor.accountLiquidity(bob.address, ZeroAddress, 0);
              // Based on the events emitted, calculate the liquidity
              // need to take into account the fixed rates that the borrow and the lent got at the time of the transaction
              const totalSupplyAmount = parseUnits("10000");
              const totalBorrowAmount = parseUnits("7000");
              const calculatedShortfall = totalSupplyAmount - (totalBorrowAmount * 2n * 15n) / 100n; // 2% * 15 days
              expect(debt - collateral).to.be.lt(calculatedShortfall);
            });
          });
        });
      });
    });

    it("should allow to leave market if there's no debt", async () => {
      await expect(auditor.exitMarket(marketDAI.target)).to.not.be.reverted;
    });

    it("should not revert when trying to exit a market that was not interacted with", async () => {
      await expect(auditor.exitMarket(marketWBTC.target)).to.not.be.reverted;
    });
  });

  describe("support for assets with different decimals", () => {
    describe("GIVEN liquidity on the USDC pool ", () => {
      beforeEach(async () => {
        await marketUSDC.depositAtMaturity(pools[0], parseUnits("3", 6), parseUnits("3", 6), laura.address);
      });

      describe("WHEN bob does a 1 sat deposit", () => {
        beforeEach(async () => {
          await marketWBTC.connect(bob).deposit(1, bob.address);
        });

        it("THEN bobs liquidity is 63000 * 0.6 * 10 ^ - 8 usd == 3.78*10^14 minimal usd units", async () => {
          const [collateral, debt] = await auditor.accountLiquidity(bob.address, ZeroAddress, 0);
          expect(collateral - debt).to.equal(parseUnits("3.78", 14));
        });

        it("AND WHEN he tries to take a 4*10^14 usd USDC loan, THEN it reverts", async () => {
          // expect liquidity to equal zero
          await expect(
            marketUSDC.connect(bob).borrowAtMaturity(pools[0], "400", "400", bob.address, bob.address),
          ).to.be.revertedWithCustomError(auditor, "InsufficientAccountLiquidity");
        });

        describe("AND WHEN he takes a 3*10^14 USDC loan", () => {
          beforeEach(async () => {
            await marketUSDC.connect(bob).borrowAtMaturity(pools[0], "300", "300", bob.address, bob.address);
          });

          it("THEN he has 3*10^12 usd left of liquidity", async () => {
            const [collateral, debt] = await auditor.accountLiquidity(bob.address, ZeroAddress, 0);
            expect(collateral - debt).to.equal(parseUnits("3", 12));
          });
        });
      });
    });

    describe("GIVEN theres liquidity on the btc market", () => {
      beforeEach(async () => {
        // laura supplies wbtc to the protocol to have lendable money in the pool
        await marketWBTC.depositAtMaturity(pools[0], parseUnits("3", 8), parseUnits("3", 8), laura.address);
      });

      describe("AND GIVEN Bob provides 60k dai (18 decimals) as collateral", () => {
        beforeEach(async () => {
          await marketDAI.connect(bob).deposit(parseUnits("60000"), bob.address);
        });
        // make sure the borrowed asset's decimals is used properly to compute liquidity
        it("WHEN he tries to take a 1btc (8 decimals) loan (100% collateralization), THEN it reverts", async () => {
          // expect liquidity to equal zero
          await expect(
            marketWBTC
              .connect(bob)
              .borrowAtMaturity(pools[0], parseUnits("1", 8), parseUnits("1", 8), bob.address, bob.address),
          ).to.be.revertedWithCustomError(auditor, "InsufficientAccountLiquidity");
        });
      });

      describe("AND GIVEN Bob provides 20k dai (18 decimals) and 40k usdc (6 decimals) as collateral", () => {
        beforeEach(async () => {
          await marketDAI.connect(bob).deposit(parseUnits("20000"), bob.address);
          await marketUSDC.connect(bob).deposit(parseUnits("40000", 6), bob.address);
        });

        describe("AND GIVEN Bob takes a 0.5wbtc loan (200% collateralization)", () => {
          beforeEach(async () => {
            await marketWBTC
              .connect(bob)
              .borrowAtMaturity(pools[0], parseUnits("0.45", 8), parseUnits("0.45", 8), bob.address, bob.address);
          });
          // this is similar to the previous test case, but instead of
          // computing the simulated liquidity with a supplyAmount of zero and
          // the to-be-loaned amount as the borrowAmount, the amount of
          // collateral to withdraw is passed as the supplyAmount
          it("WHEN he tries to withdraw the usdc (6 decimals) collateral, THEN it reverts ()", async () => {
            // expect liquidity to equal zero
            await expect(
              marketUSDC.withdraw(parseUnits("40000", 6), bob.address, bob.address),
            ).to.be.revertedWithCustomError(auditor, "InsufficientAccountLiquidity");
          });
        });
      });
    });
  });
});
