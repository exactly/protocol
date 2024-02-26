import { expect } from "chai";
import { ethers } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { ContractTransactionResponse } from "ethers";
import type { Auditor, Market, MockERC20, WETH } from "../../types";
import { DefaultEnv } from "./defaultEnv";
import futurePools from "./utils/futurePools";

const { MaxUint256, parseUnits, provider } = ethers;
const nextPoolID = futurePools(3)[2];

describe("Liquidations", function () {
  let auditor: Auditor;
  let exactlyEnv: DefaultEnv;

  let bob: SignerWithAddress;
  let alice: SignerWithAddress;
  let john: SignerWithAddress;

  let marketETH: Market;
  let marketDAI: Market;
  let marketWBTC: Market;
  let dai: MockERC20;
  let eth: WETH;
  let wbtc: MockERC20;

  let amountToBorrowDAI: string;

  let snapshot: string;

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);

    alice = await ethers.getNamedSigner("deployer");
    [bob, john] = await ethers.getUnnamedSigners();

    exactlyEnv = await DefaultEnv.create();
    auditor = exactlyEnv.auditor;

    marketETH = exactlyEnv.getMarket("WETH");
    marketDAI = exactlyEnv.getMarket("DAI");
    marketWBTC = exactlyEnv.getMarket("WBTC");
    dai = exactlyEnv.getUnderlying("DAI") as MockERC20;
    eth = exactlyEnv.getUnderlying("WETH") as WETH;
    wbtc = exactlyEnv.getUnderlying("WBTC") as MockERC20;

    // From alice to bob
    await dai.mint(bob.address, parseUnits("200000"));
    await dai.mint(john.address, parseUnits("10000"));
  });

  describe("GIVEN alice deposits USD63k worth of WBTC, USD3k worth of WETH (66k total), 63k*0.6+3k*0.7=39k liquidity AND bob deposits 65kDAI", () => {
    beforeEach(async () => {
      // deposit ETH to the protocol
      await exactlyEnv.depositSP("WETH", "1");

      // deposit WBTC to the protocol
      await exactlyEnv.depositSP("WBTC", "1");

      // bob deposits DAI to the protocol to have money in the pool
      exactlyEnv.switchWallet(bob);
      await exactlyEnv.depositMP("DAI", nextPoolID, "65000");
      await dai.connect(bob).approve(marketDAI.target, parseUnits("200000"));
      await dai.connect(john).approve(marketDAI.target, parseUnits("10000"));
      await provider.send("evm_increaseTime", [9_011]);
    });

    describe("AND GIVEN Alice takes the biggest loan she can (31920 DAI), 31920/0.8=39900", () => {
      beforeEach(async () => {
        // make WETH & WBTC count as collateral
        await auditor.enterMarket(marketETH.target);
        await auditor.enterMarket(marketWBTC.target);

        // this works because 1USD (liquidity) = 1DAI (asset to borrow)
        amountToBorrowDAI = "31920";
        // alice borrows all liquidity
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.borrowMP("DAI", nextPoolID, amountToBorrowDAI);
      });

      describe("WHEN john supplies to the smart pool & the pool matures (prices stay the same) and 20 days goes by without payment", () => {
        beforeEach(async () => {
          exactlyEnv.switchWallet(john);
          await exactlyEnv.depositSP("DAI", "10000");
          await exactlyEnv.moveInTime(nextPoolID + 86_400 * 20);
        });
        describe("AND the liquidation incentive is increased to 15%", () => {
          beforeEach(async () => {
            await auditor.setLiquidationIncentive({ liquidator: parseUnits("0.15"), lenders: parseUnits("0") });
          });
          describe("AND the position is liquidated (19kdai)", () => {
            it("THEN the liquidator seizes 19k+15% of collateral (in WBTC, 34682541 sats)", async () => {
              // 19kusd of btc + 15% incentive for liquidators
              const seizedWBTC = parseUnits("34682541", 0);

              await expect(marketDAI.connect(bob).liquidate(alice.address, parseUnits("19000"), marketWBTC.target))
                .to.emit(marketWBTC, "Seize")
                .withArgs(bob.address, alice.address, seizedWBTC);
            });
          });
        });

        describe("AND the position is liquidated a first time (19k DAI / 26.6k with penalties )", () => {
          let tx: Promise<ContractTransactionResponse>;
          let balancePreBTC: bigint;
          beforeEach(async () => {
            balancePreBTC = await exactlyEnv.getUnderlying("WBTC").connect(bob).balanceOf(bob.address);
            // 19000 USD of btc + penalties at its current price of 63000 USD + 10% incentive for liquidators
            await expect(marketDAI.connect(bob).liquidate(alice.address, parseUnits("26600"), marketWBTC.target))
              .to.emit(marketWBTC, "Seize")
              .withArgs(bob.address, alice.address, parseUnits("46444446", 0));
          });

          it("THEN the earningsAccumulator collects the penalty fees", async () => {
            const earningsAccumulator = await exactlyEnv.getMarket("DAI").earningsAccumulator();
            expect(earningsAccumulator).to.gt(parseUnits("7599"));
            expect(earningsAccumulator).to.lt(parseUnits("7600"));
          });

          it("THEN liquidator receives WBTC", async () => {
            await tx;
            const receivedBTC = parseUnits("46444446", 0);
            const balancePostBTC = await exactlyEnv.getUnderlying("WBTC").connect(bob).balanceOf(bob.address);
            expect(balancePostBTC - balancePreBTC).to.equal(receivedBTC);
          });

          it("AND 19k DAI of debt has been repaid, making debt ~18087 DAI", async () => {
            const debt = await marketDAI.previewDebt(alice.address);

            // Borrowed is 31920
            const totalBorrowAmount = parseUnits("31920");

            // penalty is 2% * 20 days = 40/100 + 1 = 140/100
            const newDebtCalculated = ((totalBorrowAmount - 19000000000011291428571n) * 140n) / 100n;

            // debt should be approximately 18087
            expect(debt).to.be.closeTo(newDebtCalculated, 10000000000000);
          });

          describe("AND WHEN the position is liquidated a second time (7k DAI)", () => {
            beforeEach(async () => {
              // 7kusd of btc at its current price of 63kusd + 10% incentive for liquidator
              await expect(marketDAI.connect(bob).liquidate(alice.address, parseUnits("7000"), marketWBTC.target))
                .to.emit(marketWBTC, "Seize")
                .withArgs(bob.address, alice.address, parseUnits("11565407", 0));
            });
            it("AND 7k DAI of debt has been repaid, making debt ~18k DAI", async () => {
              const debt = await marketDAI.previewDebt(alice.address);
              expect(debt).to.be.gt(parseUnits("11464"));
              expect(debt).to.be.lt(parseUnits("11465"));
            });
          });
        });
      });

      describe("A position can be recollateralized through liquidation", () => {
        describe("AND WHEN WETH price halves (Alices liquidity is 63k*0.6+1.5k*0.7=38850)", () => {
          beforeEach(async () => {
            await exactlyEnv.setPrice(marketETH.target, parseUnits("1500", 8));
          });

          it("THEN alice has a small (39900-38850 = 1050) liquidity shortfall", async () => {
            const [collateral, debt] = await auditor.accountLiquidity(alice.address, ethers.ZeroAddress, 0);
            expect(debt - collateral).to.eq(parseUnits("1050"));
          });

          describe("AND WHEN a liquidator repays the max amount (19kDAI)", () => {
            beforeEach(async () => {
              // 13475usd of btc at its current price of 63kusd + 10% incentive for liquidator
              await expect(
                await marketDAI.connect(bob).liquidate(alice.address, parseUnits("12250"), marketWBTC.target),
              )
                .to.emit(marketWBTC, "Seize")
                .withArgs(bob.address, alice.address, parseUnits("21388890", 0));
            });

            it("THEN alice no longer has a liquidity shortfall", async () => {
              const [collateral, debt] = await auditor.accountLiquidity(alice.address, ethers.ZeroAddress, 0);
              expect(debt).to.lt(collateral);
            });

            it("AND she has some liquidity", async () => {
              const [collateral, debt] = await auditor.accountLiquidity(alice.address, ethers.ZeroAddress, 0);
              const liquidity = collateral - debt;
              expect(liquidity).to.be.gt(parseUnits("6177"));
              expect(liquidity).to.be.lt(parseUnits("6178"));
            });
          });
        });
      });

      describe("AND WHEN WBTC price halves (Alices liquidity is 32.5k*0.6+3k*0.7=21.6k)", () => {
        beforeEach(async () => {
          await exactlyEnv.setPrice(marketWBTC.target, parseUnits("32500", 8));
        });
        describe("the collateral can be entirely depleted and still have some debt left", () => {
          describe("WHEN depleting Alices WETH collateral", () => {
            beforeEach(async () => {
              await marketDAI.connect(bob).liquidate(alice.address, parseUnits("2727"), marketETH.target);
            });
            it("THEN theres nearly no WETH supplied by Alice", async () => {
              expect(await marketETH.maxWithdraw(alice.address)).to.be.lt(parseUnits("0.001"));
            });
            describe("AND WHEN liquidating $27500 of Alices WBTC collateral", () => {
              beforeEach(async () => {
                await marketDAI.connect(bob).liquidate(alice.address, parseUnits("27500"), marketWBTC.target);
              });
              it("THEN liquidating the max amount (4500, half of the remaining debt) does not revert (it gets capped)", async () => {
                await expect(marketDAI.connect(bob).liquidate(alice.address, parseUnits("4500"), marketETH.target)).to
                  .not.be.reverted;
              });
              describe("AND WHEN liquidating the rest of the collateral", () => {
                beforeEach(async () => {
                  await exactlyEnv.setPrice(marketETH.target, parseUnits("10", 8));
                  await marketDAI.connect(bob).liquidate(alice.address, parseUnits("2045"), marketWBTC.target);
                });
                it("THEN Alice has zero WBTC deposited", async () => {
                  expect(await marketWBTC.maxWithdraw(alice.address)).to.be.lt(parseUnits("0.021", 8));
                });
                // now theres no incentive to liquidate those 258 dai
                it("AND alice still has some DAI debt", async () => {
                  expect(await marketDAI.previewDebt(alice.address)).to.be.lt(parseUnits("258"));
                });
              });
            });
          });
        });

        it("THEN alices liquidity is zero", async () => {
          // expect liquidity to be equal to zero
          const [collateral, debt] = await auditor.accountLiquidity(alice.address, ethers.ZeroAddress, 0);
          expect(collateral - debt).to.be.lt("1");
        });
        it("AND alice has a big (18k) liquidity shortfall", async () => {
          const [collateral, debt] = await auditor.accountLiquidity(alice.address, ethers.ZeroAddress, 0);
          expect(debt - collateral).to.eq(parseUnits("18300"));
        });

        it("AND trying to repay an amount of zero fails", async () => {
          // try to get all the WETH available
          // expect trying to repay zero to fail
          await expect(
            marketDAI.connect(bob).liquidate(alice.address, 0, marketETH.target),
          ).to.be.revertedWithCustomError(marketDAI, "ZeroRepay");
        });

        it("AND the position cant be liquidated by the borrower", async () => {
          // expect self liquidation to fail
          await expect(
            marketDAI.liquidate(alice.address, parseUnits("15000"), marketETH.target),
          ).to.be.revertedWithCustomError(marketDAI, "SelfLiquidation");
        });

        describe("GIVEN an insufficient allowance on the liquidator", () => {
          beforeEach(async () => {
            await dai.connect(bob).approve(marketDAI.target, parseUnits("1000"));
          });
          it("WHEN trying to liquidate, THEN it reverts with a ERC20 transfer error", async () => {
            // expect liquidation to fail because trying to liquidate
            // and repay with an amount that the contract doesn't have enough allowance for bob
            await expect(
              marketDAI.connect(bob).liquidate(alice.address, parseUnits("15000"), marketETH.target),
            ).to.be.revertedWithoutReason();
          });
        });

        describe("Liquidation error cases", () => {
          it("WHEN trying to liquidate 39850 DAI for WETH (of which there is only 3000usd), THEN it doesn't revert because the max assets gets capped", async () => {
            await expect(marketDAI.connect(bob).liquidate(alice.address, parseUnits("10000"), marketETH.target)).to.not
              .be.reverted;
          });
          it("WHEN trying to liquidate as much as possible, THEN it doesn't revert because the max assets gets capped", async () => {
            await expect(marketDAI.connect(bob).liquidate(alice.address, ethers.MaxUint256, marketETH.target)).to.not.be
              .reverted;
          });
          it("WHEN liquidating slightly more than the close factor(0.5), (20000 DAI), THEN it doesn't revert", async () => {
            await expect(marketDAI.connect(bob).liquidate(alice.address, parseUnits("20000"), marketWBTC.target)).to.not
              .be.reverted;
          });
        });
        // TODO: this should eventually be 'a position can be wiped out if its undercollateralized enough' kind of test suite
        describe("AND WHEN liquidating slightly less than the close factor (19000 DAI)", () => {
          let tx: ContractTransactionResponse;
          beforeEach(async () => {
            tx = await marketDAI.connect(bob).liquidate(alice.address, parseUnits("19000"), marketWBTC.target);
          });
          it("THEN roughly 19000 USD + 10% = 20900 of collateral (WBTC) is seized", async () => {
            // this is equivalent to 18999.9 USD, at the provided price of
            // 32500 + 10% liquidation incentive
            const seizedWBTC = parseUnits("64307693", 0);
            await expect(tx).to.emit(marketWBTC, "Seize").withArgs(bob.address, alice.address, seizedWBTC);
            expect(await wbtc.balanceOf(bob.address)).to.eq(seizedWBTC);
          });
          it("AND 19000 DAI of debt is repaid (debt covered)", async () => {
            const bobDAIBalanceBefore = parseUnits("135000");
            await expect(tx)
              .to.emit(marketDAI, "RepayAtMaturity")
              .withArgs(nextPoolID, bob.address, alice.address, parseUnits("19000"), parseUnits("19000"));
            expect(await dai.balanceOf(bob.address)).to.eq(bobDAIBalanceBefore - parseUnits("19000"));
          });
        });
      });
    });
  });

  describe("GIVEN john funds the WETH maturity pool and deposits collateral to the smart pool", () => {
    beforeEach(async () => {
      exactlyEnv.switchWallet(john);
      await eth.transfer(john.address, parseUnits("20"));
      // add WETH liquidity to the maturity
      await exactlyEnv.depositMP("WETH", futurePools(1)[0], "1.25");
      await exactlyEnv.depositMP("WETH", futurePools(2)[1], "1.25");

      await exactlyEnv.depositSP("WETH", "10");
      await exactlyEnv.enterMarket("WETH");
      await provider.send("evm_increaseTime", [9_011]);
    });
    describe("AND GIVEN alice deposits 10k DAI to the smart pool AND borrows USD8k worth of WETH (80% collateralization rate)", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.depositSP("DAI", "10000");
        await exactlyEnv.enterMarket("DAI");
        await provider.send("evm_increaseTime", [9_011]);

        await exactlyEnv.borrowMP("WETH", futurePools(1)[0], "0.93");
        await exactlyEnv.borrowMP("WETH", futurePools(2)[1], "0.93");
      });
      describe("WHEN WETH price doubles AND john borrows 10k DAI from a maturity pool (all liquidity in smart pool)", () => {
        beforeEach(async () => {
          await provider.send("evm_increaseTime", [3_600 * 2]);
          await exactlyEnv.setPrice(marketETH.target, parseUnits("8000", 8));
          exactlyEnv.switchWallet(john);
          await exactlyEnv.borrowMP("DAI", futurePools(1)[0], "10000");
        });
        it("THEN it reverts with error INSUFFICIENT_PROTOCOL_LIQUIDITY when trying to liquidate alice's positions", async () => {
          await eth.connect(john).approve(marketETH.target, parseUnits("1"));

          await expect(
            marketETH.connect(john).liquidate(alice.address, parseUnits("1"), marketDAI.target),
          ).to.be.revertedWithCustomError(marketETH, "InsufficientProtocolLiquidity");
        });
        describe("AND GIVEN a DAI liquidity deposit to the smart pool", () => {
          beforeEach(async () => {
            exactlyEnv.switchWallet(john);
            await dai.mint(john.address, parseUnits("10000"));
            await exactlyEnv.depositSP("DAI", "10000");
            await eth.connect(john).approve(marketETH.target, parseUnits("1"));
            await provider.send("evm_increaseTime", [9_011]);
          });
          it("WHEN both of alice's positions are liquidated THEN it doesn't revert", async () => {
            await expect(marketETH.connect(john).liquidate(alice.address, parseUnits("1"), marketDAI.target)).to.not.be
              .reverted;
          });
          it("AND WHEN trying to liquidate in a market where alice doesn't have borrows THEN it reverts", async () => {
            await expect(
              marketWBTC.connect(john).liquidate(alice.address, parseUnits("0.5"), marketDAI.target),
            ).to.be.revertedWithoutReason();
          });
        });
      });
    });
  });

  describe("GIVEN john funds the DAI maturity pool", () => {
    beforeEach(async () => {
      exactlyEnv.switchWallet(john);
      await dai.mint(john.address, parseUnits("20000"));
      // add DAI liquidity to the maturities
      await exactlyEnv.depositMP("DAI", futurePools(1)[0], "1000");
      await exactlyEnv.depositMP("DAI", futurePools(2)[1], "6000");
    });
    describe("AND GIVEN alice deposits USD10k worth of WETH to the smart pool AND borrows 7k DAI (70% collateralization rate)", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.depositSP("WETH", "5");
        await exactlyEnv.enterMarket("WETH");

        await exactlyEnv.borrowMP("DAI", futurePools(1)[0], "1000");
        await exactlyEnv.borrowMP("DAI", futurePools(2)[1], "6000");
        await provider.send("evm_increaseTime", [9_011]);
      });
      describe("WHEN 20 days goes by without payment, WETH price halves AND alice's first borrow is liquidated with a higher amount as repayment", () => {
        let johnETHBalanceBefore: bigint;
        let johnDAIBalanceBefore: bigint;
        beforeEach(async () => {
          await exactlyEnv.setPrice(marketETH.target, parseUnits("1500", 8));
          await exactlyEnv.moveInTimeAndMine(futurePools(1)[0] + 86_400 * 20);
          johnETHBalanceBefore = await eth.balanceOf(john.address);
          johnDAIBalanceBefore = await dai.balanceOf(john.address);
          await dai.connect(john).approve(marketDAI.target, parseUnits("6400"));
          // for maturity pool 1 alice's debt (borrowed + penalties) is aprox 1400
          // in the liquidation, try repaying 6000 (aprox 2100 should be returned and not accounted to seize assets)
          // total alice borrows are 7000 (+ 400 penalties), so for dynamic close factor max to repay is 6800
          await marketDAI.connect(john).liquidate(alice.address, parseUnits("6400"), marketETH.target);
        });
        it("THEN the liquidator does not seize more ETH assets than it should", async () => {
          // if john liquidates and repays 6000 + 400 in penalties, then he should seize 4.26 ETH (1500 each) + liquidation incentive (10%)
          // 4.26 + 0.426 = 4.686 ETH
          const johnETHBalanceAfter = await eth.balanceOf(john.address);
          expect(johnETHBalanceBefore).to.not.equal(johnETHBalanceAfter);
          expect(johnETHBalanceAfter - johnETHBalanceBefore).to.be.gt(parseUnits("4.69"));
          expect(johnETHBalanceAfter - johnETHBalanceBefore).to.be.lt(parseUnits("4.70"));
        });
        it("THEN the liquidator doesn't receive back any DAI spare repayment amount", async () => {
          const johnDAIBalanceAfter = await dai.balanceOf(john.address);
          expect(johnDAIBalanceBefore).to.not.equal(johnDAIBalanceAfter);
          expect(johnDAIBalanceBefore - johnDAIBalanceAfter).to.be.eq(parseUnits("6400"));
        });
      });
      describe("WHEN WETH price suddenly decreases (now alice has bad debt) AND she gets liquidated", () => {
        beforeEach(async () => {
          await dai.connect(john).approve(marketDAI.target, MaxUint256);
          await dai.mint(john.address, parseUnits("100000"));
          await marketDAI.connect(john).deposit(parseUnits("100000"), john.address);
          await provider.send("evm_increaseTime", [9_011]);

          // distribute earnings to accumulator
          await exactlyEnv.setRate("1");
          await marketDAI.setBackupFeeRate(parseUnits("1"));
          await marketDAI
            .connect(john)
            .borrowAtMaturity(futurePools(1)[0], parseUnits("10000"), parseUnits("20000"), john.address, john.address);
          await marketDAI
            .connect(john)
            .depositAtMaturity(futurePools(1)[0], parseUnits("10000"), parseUnits("10000"), john.address);

          await exactlyEnv.setPrice(marketETH.target, parseUnits("100", 8));
          await marketDAI.connect(john).liquidate(alice.address, MaxUint256, marketETH.target);
        });
        it("THEN alice's debt is cleared", async () => {
          expect(await marketDAI.previewDebt(alice.address)).to.be.eq(0);
        });
        it("THEN alice's collateral is zero", async () => {
          const accountSnapshot = await marketETH.accountSnapshot(alice.address);
          expect(accountSnapshot[0]).to.be.eq(0);
        });
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
