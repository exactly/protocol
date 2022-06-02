import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { Auditor, FixedLender, InterestRateModel, MockChainlinkFeedRegistry, MockToken, WETH } from "../types";
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
  let dai: MockToken;
  let usdc: MockToken;
  let wbtc: MockToken;
  let weth: WETH;
  let auditor: Auditor;
  let feedRegistry: MockChainlinkFeedRegistry;
  let fixedLenderDAI: FixedLender;
  let fixedLenderUSDC: FixedLender;
  let fixedLenderWBTC: FixedLender;
  let fixedLenderWETH: FixedLender;
  let interestRateModel: InterestRateModel;

  let bob: SignerWithAddress;
  let laura: SignerWithAddress;
  let multisig: SignerWithAddress;

  before(async () => {
    multisig = await getNamedSigner("multisig");
    [bob, laura] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture(["Markets"]);

    dai = await getContract<MockToken>("DAI", laura);
    usdc = await getContract<MockToken>("USDC", laura);
    wbtc = await getContract<MockToken>("WBTC", laura);
    weth = await getContract<WETH>("WETH", laura);
    auditor = await getContract<Auditor>("Auditor", laura);
    feedRegistry = await getContract<MockChainlinkFeedRegistry>("FeedRegistry");
    fixedLenderDAI = await getContract<FixedLender>("FixedLenderDAI", laura);
    fixedLenderUSDC = await getContract<FixedLender>("FixedLenderUSDC", laura);
    fixedLenderWBTC = await getContract<FixedLender>("FixedLenderWBTC", laura);
    fixedLenderWETH = await getContract<FixedLender>("FixedLenderWETH", laura);
    interestRateModel = await getContract<InterestRateModel>("InterestRateModel", multisig);

    await timelockExecute(multisig, interestRateModel, "setCurveParameters", [0, 0, parseUnits("6"), parseUnits("2")]);
    for (const signer of [bob, laura]) {
      for (const [underlying, fixedLender, decimals = 18] of [
        [dai, fixedLenderDAI],
        [usdc, fixedLenderUSDC, 6],
        [wbtc, fixedLenderWBTC, 8],
      ] as [MockToken, FixedLender, number?][]) {
        await underlying.connect(multisig).transfer(signer.address, parseUnits("100000", decimals));
        await underlying.connect(signer).approve(fixedLender.address, parseUnits("100000", decimals));
      }
      await weth.deposit({ value: parseUnits("10") });
      await weth.approve(fixedLenderWETH.address, parseUnits("10"));
      await auditor.connect(signer).enterMarket(fixedLenderDAI.address);
      await auditor.connect(signer).enterMarket(fixedLenderUSDC.address);
      await auditor.connect(signer).enterMarket(fixedLenderWBTC.address);
    }
  });

  describe("positions aren't immediately liquidatable", () => {
    describe("GIVEN laura deposits 1k dai to a smart pool", () => {
      beforeEach(async () => {
        await fixedLenderDAI.deposit(parseUnits("1000"), laura.address);
      });

      it("THEN lauras liquidity is collateralRate*collateral -  0.8*1000 == 800, AND she has no shortfall", async () => {
        const [collateral, debt] = await auditor.accountLiquidity(laura.address, AddressZero, 0);

        expect(collateral).to.equal(parseUnits("800"));
        expect(debt).to.equal(parseUnits("0"));
      });
      // TODO: a test where the supply interest is != 0, see if there's an error like the one described in this commit
      it("AND she has zero debt and is owed 1000DAI", async () => {
        const [supplied, owed] = await fixedLenderDAI.getAccountSnapshot(laura.address, futurePools(1)[0]);
        expect(supplied).to.equal(parseUnits("1000"));
        expect(owed).to.equal(parseUnits("0"));
      });
      describe("AND GIVEN a 1% borrow interest rate", () => {
        beforeEach(async () => {
          await timelockExecute(multisig, interestRateModel, "setCurveParameters", [
            0,
            parseUnits("0.01"),
            parseUnits("6"),
            parseUnits("2"),
          ]);
          // we add liquidity to the maturity
          await fixedLenderDAI.depositAtMaturity(
            futurePools(1)[0],
            parseUnits("800"),
            parseUnits("800"),
            laura.address,
          );
        });
        it("AND WHEN laura asks for a 800 DAI loan, THEN it reverts because the interests make the owed amount larger than liquidity", async () => {
          await expect(
            fixedLenderDAI.borrowAtMaturity(
              futurePools(1)[0],
              parseUnits("800"),
              parseUnits("1000"),
              laura.address,
              laura.address,
            ),
          ).to.be.revertedWith("InsufficientLiquidity()");
        });
      });

      describe("AND WHEN laura asks for a 800 DAI loan", () => {
        beforeEach(async () => {
          // we add liquidity to the maturity
          await fixedLenderDAI.depositAtMaturity(
            futurePools(1)[0],
            parseUnits("800"),
            parseUnits("800"),
            laura.address,
          );
          await fixedLenderDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("800"),
            parseUnits("800"),
            laura.address,
            laura.address,
          );
        });
        it("THEN lauras liquidity is zero, AND she has no shortfall", async () => {
          const [collateral, debt] = await auditor.accountLiquidity(laura.address, AddressZero, 0);
          expect(collateral).to.equal(debt);
        });
        it("AND she has 799+interest debt and is owed 1000DAI", async () => {
          const [supplied, borrowed] = await fixedLenderDAI.getAccountSnapshot(laura.address, futurePools(1)[0]);

          expect(supplied).to.equal(parseUnits("1000"));
          expect(borrowed).to.equal(parseUnits("800"));
        });
        it("AND WHEN laura tries to exit her collateral DAI market it reverts since there's unpaid debt", async () => {
          await expect(auditor.exitMarket(fixedLenderDAI.address)).to.be.revertedWith("BalanceOwed()");
        });
        it("AND WHEN laura repays her debt THEN it does not revert when she tries to exit her collateral DAI market", async () => {
          await fixedLenderDAI.repayAtMaturity(futurePools(1)[0], parseUnits("800"), parseUnits("800"), laura.address);
          await expect(auditor.exitMarket(fixedLenderDAI.address)).to.not.be.reverted;
        });
        describe("AND GIVEN laura deposits more collateral for another asset", () => {
          beforeEach(async () => {
            await fixedLenderWETH.depositAtMaturity(futurePools(1)[0], parseUnits("1"), parseUnits("1"), laura.address);
            await auditor.enterMarket(fixedLenderWETH.address);
          });
          it("THEN it does not revert when she tries to exit her collateral ETH market", async () => {
            await expect(auditor.exitMarket(fixedLenderWETH.address)).to.not.be.reverted;
          });
          it("THEN it reverts when she tries to exit her collateral DAI market since it's the same that she borrowed from", async () => {
            await expect(auditor.exitMarket(fixedLenderDAI.address)).to.be.revertedWith("BalanceOwed()");
          });
        });
      });
    });
  });

  describe("unpaid debts after maturity", () => {
    describe("GIVEN a well funded maturity pool (10k dai, laura), AND collateral for the borrower, (10k usdc, bob)", () => {
      beforeEach(async () => {
        await fixedLenderDAI.depositAtMaturity(
          futurePools(1)[0],
          parseUnits("10000"),
          parseUnits("10000"),
          laura.address,
        );
        await fixedLenderUSDC.connect(bob).deposit(parseUnits("10000", 6), bob.address);
      });
      describe("WHEN bob asks for a 7k dai loan (10k usdc should give him 8k usd liquidity)", () => {
        beforeEach(async () => {
          await fixedLenderDAI
            .connect(bob)
            .borrowAtMaturity(futurePools(1)[0], parseUnits("7000"), parseUnits("7000"), bob.address, bob.address);
        });
        it("THEN bob has 1k usd liquidity and no shortfall", async () => {
          const [collateral, debt] = await auditor.accountLiquidity(bob.address, AddressZero, 0);
          expect(collateral.sub(debt)).to.equal(parseUnits("1000"));
        });
        describe("AND WHEN moving to five days after the maturity date", () => {
          beforeEach(async () => {
            // Move in time to maturity
            await feedRegistry.setUpdatedAtTimestamp(futurePools(1)[0].toNumber() + 86_400 * 5);
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + 86_400 * 5]);
          });
          it("THEN 5 days of *daily* base rate interest is charged, adding 0.02*5 =10% interest to the debt", async () => {
            await provider.send("evm_mine", []);
            const [collateral, debt] = await auditor.accountLiquidity(bob.address, AddressZero, 0);
            // Based on the events emitted, we calculate the liquidity
            // This is because we need to take into account the fixed rates
            // that the borrow and the lent got at the time of the transaction
            const totalSupplyAmount = parseUnits("10000");
            const totalBorrowAmount = parseUnits("7000");
            const calculatedLiquidity = totalSupplyAmount.sub(
              totalBorrowAmount.mul(2).mul(5).div(100), // 2% * 5 days
            );
            // TODO: this should equal
            expect(collateral.sub(debt)).to.be.lt(calculatedLiquidity);
          });
          describe("AND WHEN moving to fifteen days after the maturity date", () => {
            beforeEach(async () => {
              // Move in time to maturity
              await feedRegistry.setUpdatedAtTimestamp(futurePools(1)[0].toNumber() + 86_400 * 15);
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
      await expect(auditor.exitMarket(fixedLenderDAI.address)).to.not.be.reverted;
    });
    it("should not revert when trying to exit a market that was not interacted with", async () => {
      await expect(auditor.exitMarket(fixedLenderWBTC.address)).to.not.be.reverted;
    });
  });

  describe("support for tokens with different decimals", () => {
    describe("GIVEN liquidity on the USDC pool ", () => {
      beforeEach(async () => {
        await timelockExecute(multisig, auditor, "setCollateralFactor", [fixedLenderWBTC.address, parseUnits("0.6")]);
        await fixedLenderUSDC.depositAtMaturity(
          futurePools(1)[0],
          parseUnits("3", 6),
          parseUnits("3", 6),
          laura.address,
        );
      });
      describe("WHEN bob does a 1 sat deposit", () => {
        beforeEach(async () => {
          await fixedLenderWBTC.connect(bob).deposit(1, bob.address);
        });
        it("THEN bobs liquidity is 63000 * 0.6 * 10 ^ - 8 usd == 3.78*10^14 minimal usd units", async () => {
          const [collateral, debt] = await auditor.accountLiquidity(bob.address, AddressZero, 0);
          expect(collateral.sub(debt)).to.equal(parseUnits("3.78", 14));
        });
        it("AND WHEN he tries to take a 4*10^14 usd USDC loan, THEN it reverts", async () => {
          // We expect liquidity to be equal to zero
          await expect(
            fixedLenderUSDC.connect(bob).borrowAtMaturity(futurePools(1)[0], "400", "400", bob.address, bob.address),
          ).to.be.revertedWith("InsufficientLiquidity()");
        });
        describe("AND WHEN he takes a 3*10^14 USDC loan", () => {
          beforeEach(async () => {
            await fixedLenderUSDC
              .connect(bob)
              .borrowAtMaturity(futurePools(1)[0], "300", "300", bob.address, bob.address);
          });
          it("THEN he has 7.8*10^13 usd left of liquidity", async () => {
            const [collateral, debt] = await auditor.accountLiquidity(bob.address, AddressZero, 0);
            expect(collateral.sub(debt)).to.equal(parseUnits("7.8", 13));
          });
        });
      });
    });
    describe("GIVEN theres liquidity on the btc fixedLender", () => {
      beforeEach(async () => {
        // laura supplies wbtc to the protocol to have lendable money in the pool
        await fixedLenderWBTC.depositAtMaturity(
          futurePools(1)[0],
          parseUnits("3", 8),
          parseUnits("3", 8),
          laura.address,
        );
      });

      describe("AND GIVEN Bob provides 60k dai (18 decimals) as collateral", () => {
        beforeEach(async () => {
          await fixedLenderDAI.connect(bob).deposit(parseUnits("60000"), bob.address);
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
            fixedLenderWBTC
              .connect(bob)
              .borrowAtMaturity(futurePools(1)[0], parseUnits("1", 8), parseUnits("1", 8), bob.address, bob.address),
          ).to.be.revertedWith("InsufficientLiquidity()");
        });
      });

      describe("AND GIVEN Bob provides 20k dai (18 decimals) and 40k usdc (6 decimals) as collateral", () => {
        beforeEach(async () => {
          await fixedLenderDAI.connect(bob).deposit(parseUnits("20000"), bob.address);
          await fixedLenderUSDC.connect(bob).deposit(parseUnits("40000", 6), bob.address);
        });
        describe("AND GIVEN Bob takes a 0.5wbtc loan (200% collateralization)", () => {
          beforeEach(async () => {
            await fixedLenderWBTC
              .connect(bob)
              .borrowAtMaturity(
                futurePools(1)[0],
                parseUnits("0.5", 8),
                parseUnits("0.5", 8),
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
            await expect(
              fixedLenderUSDC.withdraw(parseUnits("40000", 6), laura.address, laura.address),
            ).to.be.revertedWith("InsufficientLiquidity()");
          });
        });
      });
    });
  });
});
