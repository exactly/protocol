import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { Auditor, Market, InterestRateModel, MockERC20, MockPriceFeed, WETH } from "../types";
import timelockExecute from "./utils/timelockExecute";
import futurePools from "./utils/futurePools";

const {
  constants: { AddressZero },
  utils: { parseUnits },
  getUnnamedSigners,
  getNamedSigner,
  getContract,
  provider,
} = ethers;

describe("Liquidity computations", function () {
  let dai: MockERC20;
  let usdc: MockERC20;
  let wbtc: MockERC20;
  let weth: WETH;
  let auditor: Auditor;
  let priceFeedDAI: MockPriceFeed;
  let priceFeedUSDC: MockPriceFeed;
  let priceFeedWBTC: MockPriceFeed;
  let priceFeedWETH: MockPriceFeed;
  let marketDAI: Market;
  let marketUSDC: Market;
  let marketWBTC: Market;
  let marketWETH: Market;
  let interestRateModel: InterestRateModel;

  let bob: SignerWithAddress;
  let laura: SignerWithAddress;
  let multisig: SignerWithAddress;

  before(async () => {
    multisig = await getNamedSigner("multisig");
    [bob, laura] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture("Markets");

    dai = await getContract<MockERC20>("DAI", laura);
    usdc = await getContract<MockERC20>("USDC", laura);
    wbtc = await getContract<MockERC20>("WBTC", laura);
    weth = await getContract<WETH>("WETH", laura);
    auditor = await getContract<Auditor>("Auditor", laura);
    priceFeedDAI = await getContract<MockPriceFeed>("PriceFeedDAI");
    priceFeedUSDC = await getContract<MockPriceFeed>("PriceFeedUSDC");
    priceFeedWBTC = await getContract<MockPriceFeed>("PriceFeedWBTC");
    priceFeedWETH = await getContract<MockPriceFeed>("PriceFeedWETH");
    marketDAI = await getContract<Market>("MarketDAI", laura);
    marketUSDC = await getContract<Market>("MarketUSDC", laura);
    marketWBTC = await getContract<Market>("MarketWBTC", laura);
    marketWETH = await getContract<Market>("MarketWETH", laura);
    interestRateModel = await getContract<InterestRateModel>("InterestRateModel", multisig);

    await timelockExecute(multisig, interestRateModel, "setFixedParameters", [
      [0, 0, parseUnits("6")],
      parseUnits("2"),
    ]);
    for (const signer of [bob, laura]) {
      for (const [underlying, market, decimals = 18] of [
        [dai, marketDAI],
        [usdc, marketUSDC, 6],
        [wbtc, marketWBTC, 8],
      ] as [MockERC20, Market, number?][]) {
        await underlying.connect(multisig).mint(signer.address, parseUnits("100000", decimals));
        await underlying.connect(signer).approve(market.address, parseUnits("100000", decimals));
      }
      await weth.deposit({ value: parseUnits("10") });
      await weth.approve(marketWETH.address, parseUnits("10"));
      await auditor.connect(signer).enterMarket(marketDAI.address);
      await auditor.connect(signer).enterMarket(marketUSDC.address);
      await auditor.connect(signer).enterMarket(marketWBTC.address);
    }
  });

  describe("positions aren't immediately liquidatable", () => {
    describe("GIVEN laura deposits 1k dai to a smart pool", () => {
      beforeEach(async () => {
        await marketDAI.deposit(parseUnits("1000"), laura.address);
      });

      it("THEN lauras liquidity is adjustFactor*collateral -  0.8*1000 == 800, AND she has no shortfall", async () => {
        const [collateral, debt] = await auditor.accountLiquidity(laura.address, AddressZero, 0);

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
          await timelockExecute(multisig, interestRateModel, "setFixedParameters", [
            [0, parseUnits("0.01"), parseUnits("6")],
            parseUnits("2"),
          ]);
          // we add liquidity to the maturity
          await marketDAI.depositAtMaturity(futurePools(1)[0], parseUnits("800"), parseUnits("800"), laura.address);
        });
        it("AND WHEN laura asks for a 800 DAI loan, THEN it reverts because the interests make the owed amount larger than liquidity", async () => {
          await expect(
            marketDAI.borrowAtMaturity(
              futurePools(1)[0],
              parseUnits("800"),
              parseUnits("1000"),
              laura.address,
              laura.address,
            ),
          ).to.be.revertedWith("InsufficientAccountLiquidity()");
        });
      });

      describe("AND WHEN laura asks for a 640 DAI loan (640 / 0.8 = 800)", () => {
        beforeEach(async () => {
          // we add liquidity to the maturity
          await marketDAI.depositAtMaturity(futurePools(1)[0], parseUnits("640"), parseUnits("640"), laura.address);
          await marketDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("640"),
            parseUnits("800"),
            laura.address,
            laura.address,
          );
        });
        it("THEN lauras liquidity is zero, AND she has no shortfall", async () => {
          const [collateral, debt] = await auditor.accountLiquidity(laura.address, AddressZero, 0);
          expect(collateral).to.equal(debt);
        });
        it("AND she has 640 debt and is owed 1000DAI", async () => {
          const [supplied, borrowed] = await marketDAI.accountSnapshot(laura.address);

          expect(supplied).to.equal(parseUnits("1000"));
          expect(borrowed).to.equal(parseUnits("640"));
        });
        it("AND WHEN laura tries to exit her collateral DAI market it reverts since there's unpaid debt", async () => {
          await expect(auditor.exitMarket(marketDAI.address)).to.be.revertedWith("RemainingDebt()");
        });
        it("AND WHEN laura repays her debt THEN it does not revert when she tries to exit her collateral DAI market", async () => {
          await marketDAI.repayAtMaturity(futurePools(1)[0], parseUnits("640"), parseUnits("640"), laura.address);
          await expect(auditor.exitMarket(marketDAI.address)).to.not.be.reverted;
        });
        describe("AND GIVEN laura deposits more collateral for another asset", () => {
          beforeEach(async () => {
            await marketWETH.depositAtMaturity(futurePools(1)[0], parseUnits("1"), parseUnits("1"), laura.address);
            await auditor.enterMarket(marketWETH.address);
          });
          it("THEN it does not revert when she tries to exit her collateral ETH market", async () => {
            await expect(auditor.exitMarket(marketWETH.address)).to.not.be.reverted;
          });
          it("THEN it reverts when she tries to exit her collateral DAI market since it's the same that she borrowed from", async () => {
            await expect(auditor.exitMarket(marketDAI.address)).to.be.revertedWith("RemainingDebt()");
          });
        });
      });
    });
  });

  describe("unpaid debts after maturity", () => {
    describe("GIVEN a well funded maturity pool (10k dai, laura), AND collateral for the borrower, (10k usdc, bob)", () => {
      beforeEach(async () => {
        await marketDAI.depositAtMaturity(futurePools(1)[0], parseUnits("10000"), parseUnits("10000"), laura.address);
        await marketUSDC.connect(bob).deposit(parseUnits("10000", 6), bob.address);
      });
      describe("WHEN bob asks for a 5600 dai loan (10k usdc should give him 6400 DAI liquidity)", () => {
        beforeEach(async () => {
          await marketDAI
            .connect(bob)
            .borrowAtMaturity(futurePools(1)[0], parseUnits("5600"), parseUnits("5600"), bob.address, bob.address);
        });
        it("THEN bob has 1k usd liquidity and no shortfall", async () => {
          const [collateral, debt] = await auditor.accountLiquidity(bob.address, AddressZero, 0);
          expect(collateral.sub(debt)).to.equal(parseUnits("1000"));
        });
        describe("AND WHEN moving to five days after the maturity date", () => {
          beforeEach(async () => {
            // Move in time to maturity
            await priceFeedDAI.setUpdatedAt(futurePools(1)[0].toNumber() + 86_400 * 5);
            await priceFeedUSDC.setUpdatedAt(futurePools(1)[0].toNumber() + 86_400 * 5);
            await priceFeedWBTC.setUpdatedAt(futurePools(1)[0].toNumber() + 86_400 * 5);
            await priceFeedWETH.setUpdatedAt(futurePools(1)[0].toNumber() + 86_400 * 5);
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + 86_400 * 5]);
          });
          it("THEN 5 days of *daily* base rate interest is charged, adding 0.02*5 =10% interest to the debt", async () => {
            await provider.send("evm_mine", []);
            const [collateral, debt] = await auditor.accountLiquidity(bob.address, AddressZero, 0);
            // Based on the events emitted, we calculate the liquidity
            // This is because we need to take into account the fixed rates
            // that the borrow and the lent got at the time of the transaction
            const totalSupplyAmount = parseUnits("10000");
            const totalBorrowAmount = parseUnits("5400");
            const calculatedLiquidity = totalSupplyAmount.sub(
              totalBorrowAmount.mul(2).mul(5).div(100), // 2% * 5 days
            );
            // TODO: this should equal
            expect(collateral.sub(debt)).to.be.lt(calculatedLiquidity);
          });
          describe("AND WHEN moving to fifteen days after the maturity date", () => {
            beforeEach(async () => {
              // Move in time to maturity
              await priceFeedDAI.setUpdatedAt(futurePools(1)[0].toNumber() + 86_400 * 15);
              await priceFeedUSDC.setUpdatedAt(futurePools(1)[0].toNumber() + 86_400 * 15);
              await priceFeedWBTC.setUpdatedAt(futurePools(1)[0].toNumber() + 86_400 * 15);
              await priceFeedWETH.setUpdatedAt(futurePools(1)[0].toNumber() + 86_400 * 15);
              await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + 86_400 * 15]);
            });
            it("THEN 15 days of *daily* base rate interest is charged, adding 0.02*15 =35% interest to the debt, causing a shortfall", async () => {
              await provider.send("evm_mine", []);
              const [collateral, debt] = await auditor.accountLiquidity(bob.address, AddressZero, 0);
              // Based on the events emitted, we calculate the liquidity
              // This is because we need to take into account the fixed rates
              // that the borrow and the lent got at the time of the transaction
              const totalSupplyAmount = parseUnits("10000");
              const totalBorrowAmount = parseUnits("7000");
              const calculatedShortfall = totalSupplyAmount.sub(
                totalBorrowAmount.mul(2).mul(15).div(100), // 2% * 15 days
              );
              expect(debt.sub(collateral)).to.be.lt(calculatedShortfall);
            });
          });
        });
      });
    });
    it("should allow to leave market if there's no debt", async () => {
      await expect(auditor.exitMarket(marketDAI.address)).to.not.be.reverted;
    });
    it("should not revert when trying to exit a market that was not interacted with", async () => {
      await expect(auditor.exitMarket(marketWBTC.address)).to.not.be.reverted;
    });
  });

  describe("support for tokens with different decimals", () => {
    describe("GIVEN liquidity on the USDC pool ", () => {
      beforeEach(async () => {
        await timelockExecute(multisig, auditor, "setAdjustFactor", [marketWBTC.address, parseUnits("0.6")]);
        await marketUSDC.depositAtMaturity(futurePools(1)[0], parseUnits("3", 6), parseUnits("3", 6), laura.address);
      });
      describe("WHEN bob does a 1 sat deposit", () => {
        beforeEach(async () => {
          await marketWBTC.connect(bob).deposit(1, bob.address);
        });
        it("THEN bobs liquidity is 63000 * 0.6 * 10 ^ - 8 usd == 3.78*10^14 minimal usd units", async () => {
          const [collateral, debt] = await auditor.accountLiquidity(bob.address, AddressZero, 0);
          expect(collateral.sub(debt)).to.equal(parseUnits("3.78", 14));
        });
        it("AND WHEN he tries to take a 4*10^14 usd USDC loan, THEN it reverts", async () => {
          // We expect liquidity to be equal to zero
          await expect(
            marketUSDC.connect(bob).borrowAtMaturity(futurePools(1)[0], "400", "400", bob.address, bob.address),
          ).to.be.revertedWith("InsufficientAccountLiquidity()");
        });
        describe("AND WHEN he takes a 3*10^14 USDC loan", () => {
          beforeEach(async () => {
            await marketUSDC.connect(bob).borrowAtMaturity(futurePools(1)[0], "300", "300", bob.address, bob.address);
          });
          it("THEN he has 3*10^12 usd left of liquidity", async () => {
            const [collateral, debt] = await auditor.accountLiquidity(bob.address, AddressZero, 0);
            expect(collateral.sub(debt)).to.equal(parseUnits("3", 12));
          });
        });
      });
    });
    describe("GIVEN theres liquidity on the btc market", () => {
      beforeEach(async () => {
        // laura supplies wbtc to the protocol to have lendable money in the pool
        await marketWBTC.depositAtMaturity(futurePools(1)[0], parseUnits("3", 8), parseUnits("3", 8), laura.address);
      });

      describe("AND GIVEN Bob provides 60k dai (18 decimals) as collateral", () => {
        beforeEach(async () => {
          await marketDAI.connect(bob).deposit(parseUnits("60000"), bob.address);
        });
        // Here I'm trying to make sure we use the borrowed token's decimals
        // properly to compute liquidity
        // if we assume (wrongly) that all tokens have 18 decimals, then computing
        // the simulated liquidity for a token  with less than 18 decimals will
        // enable the creation of an undercollateralized loan, since the
        // simulated liquidity would be orders of magnitude lower than the real
        // one
        it("WHEN he tries to take a 1btc (8 decimals) loan (100% collateralization), THEN it reverts", async () => {
          // We expect liquidity to be equal to zero
          await expect(
            marketWBTC
              .connect(bob)
              .borrowAtMaturity(futurePools(1)[0], parseUnits("1", 8), parseUnits("1", 8), bob.address, bob.address),
          ).to.be.revertedWith("InsufficientAccountLiquidity()");
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
              .borrowAtMaturity(
                futurePools(1)[0],
                parseUnits("0.45", 8),
                parseUnits("0.45", 8),
                bob.address,
                bob.address,
              );
          });
          // this is similar to the previous test case, but instead of
          // computing the simulated liquidity with a supplyAmount of zero and
          // the to-be-loaned amount as the borrowAmount, the amount of
          // collateral to withdraw is passed as the supplyAmount
          it("WHEN he tries to withdraw the usdc (6 decimals) collateral, THEN it reverts ()", async () => {
            // We expect liquidity to be equal to zero
            await expect(marketUSDC.withdraw(parseUnits("40000", 6), bob.address, bob.address)).to.be.revertedWith(
              "InsufficientAccountLiquidity()",
            );
          });
        });
      });
    });
  });
});
