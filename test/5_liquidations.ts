import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv } from "./defaultEnv";
import futurePools from "./utils/futurePools";

const nextPoolID = futurePools(3)[2].toNumber();

describe("Liquidations", function () {
  let auditor: Contract;
  let exactlyEnv: DefaultEnv;

  let bob: SignerWithAddress;
  let alice: SignerWithAddress;
  let john: SignerWithAddress;

  let fixedLenderETH: Contract;
  let fixedLenderDAI: Contract;
  let dai: Contract;
  let eth: Contract;
  let fixedLenderWBTC: Contract;
  let wbtc: Contract;

  let amountToBorrowDAI: string;

  let snapshot: any;
  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    [alice, bob, john] = await ethers.getSigners();

    exactlyEnv = await DefaultEnv.create({});
    auditor = exactlyEnv.auditor;

    fixedLenderETH = exactlyEnv.getFixedLender("WETH");
    fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    dai = exactlyEnv.getUnderlying("DAI");
    eth = exactlyEnv.getUnderlying("WETH");
    fixedLenderWBTC = exactlyEnv.getFixedLender("WBTC");
    wbtc = exactlyEnv.getUnderlying("WBTC");

    // From alice to bob
    await dai.mint(bob.address, parseUnits("200000"));
    await dai.mint(john.address, parseUnits("10000"));
  });

  describe("GIVEN alice deposits USD63k worth of WBTC, USD3k worth of WETH (66k total), 63k*0.6+3k*0.7=39k liquidity AND bob deposits 65kDAI", () => {
    beforeEach(async () => {
      // we deposit ETH to the protocol
      await exactlyEnv.depositSP("WETH", "1");

      // we deposit WBTC to the protocol
      await exactlyEnv.depositSP("WBTC", "1");

      // bob deposits DAI to the protocol to have money in the pool
      exactlyEnv.switchWallet(bob);
      await exactlyEnv.depositMP("DAI", nextPoolID, "65000");
      await dai.connect(bob).approve(fixedLenderDAI.address, parseUnits("200000"));
      await dai.connect(john).approve(fixedLenderDAI.address, parseUnits("10000"));
    });

    describe("AND GIVEN Alice takes the biggest loan she can (31920 DAI), 31920/0.8=39900", () => {
      beforeEach(async () => {
        // we make WETH & WBTC count as collateral
        await auditor.enterMarket(fixedLenderETH.address);
        await auditor.enterMarket(fixedLenderWBTC.address);

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
            let tx: any;
            beforeEach(async () => {
              tx = fixedLenderDAI.connect(bob).liquidate(alice.address, parseUnits("19000"), fixedLenderWBTC.address);
              await tx;
            });
            it("THEN the liquidator seizes 19k+15% of collateral (in WBTC, 34682541 sats)", async () => {
              // 19kusd of btc + 15% incentive for liquidators
              const seizedWBTC = parseUnits("34682541", 0);

              await expect(tx).to.emit(fixedLenderWBTC, "AssetSeized").withArgs(bob.address, alice.address, seizedWBTC);
            });
          });
        });

        describe("AND the position is liquidated a first time (19k DAI / 26.6k with penalties )", () => {
          let tx: any;
          let balancePreBTC: BigNumber;
          beforeEach(async () => {
            balancePreBTC = await exactlyEnv.getUnderlying("WBTC").connect(bob).balanceOf(bob.address);
            tx = fixedLenderDAI.connect(bob).liquidate(alice.address, parseUnits("26600"), fixedLenderWBTC.address);
            await tx;
          });
          it("THEN the liquidator seizes 19k+10% of collateral (WBTC)", async () => {
            // 19000 USD of btc + penalties at its current price of 63000 USD + 10% incentive for liquidators
            const seizedWBTC = parseUnits("46444446", 0);
            await expect(tx).to.emit(fixedLenderWBTC, "AssetSeized").withArgs(bob.address, alice.address, seizedWBTC);
          });

          it("THEN the smartPoolEarningsAccumulator collects the penalty fees", async () => {
            const smartPoolEarningsAccumulator = await exactlyEnv.getFixedLender("DAI").smartPoolEarningsAccumulator();
            expect(smartPoolEarningsAccumulator).to.gt(parseUnits("7599"));
            expect(smartPoolEarningsAccumulator).to.lt(parseUnits("7600"));
          });

          it("THEN liquidator receives WBTC", async () => {
            await tx;
            const receivedBTC = parseUnits("46444446", 0);
            const balancePostBTC = await exactlyEnv.getUnderlying("WBTC").connect(bob).balanceOf(bob.address);
            expect(balancePostBTC.sub(balancePreBTC)).to.equal(receivedBTC);
          });

          it("AND 19k DAI of debt has been repaid, making debt ~18087 DAI", async () => {
            const debt = await fixedLenderDAI.getDebt(alice.address);

            // Borrowed is 31920
            const totalBorrowAmount = parseUnits("31920");

            // penalty is 2% * 20 days = 40/100 + 1 = 140/100
            const debtCovered = BigNumber.from("19000000000011291428571");
            const newDebtCalculated = totalBorrowAmount.sub(debtCovered).mul(140).div(100);

            // debt should be approximately 18087
            expect(debt).to.be.closeTo(newDebtCalculated, 10000000000000);
          });

          describe("AND WHEN the position is liquidated a second time (7k DAI)", () => {
            beforeEach(async () => {
              tx = fixedLenderDAI.connect(bob).liquidate(alice.address, parseUnits("7000"), fixedLenderWBTC.address);
              await tx;
            });
            it("THEN the liquidator seizes 7k+10% of collateral (WBTC)", async () => {
              // 7kusd of btc at its current price of 63kusd + 10% incentive for liquidator
              const seizedWBTC = parseUnits("11565407", 0);
              await expect(tx).to.emit(fixedLenderWBTC, "AssetSeized").withArgs(bob.address, alice.address, seizedWBTC);
            });
            it("AND 7k DAI of debt has been repaid, making debt ~18k DAI", async () => {
              const debt = await fixedLenderDAI.getDebt(alice.address);
              expect(debt).to.be.gt(parseUnits("11464"));
              expect(debt).to.be.lt(parseUnits("11465"));
            });
          });
        });
      });

      describe("A position can be recollateralized through liquidation", () => {
        describe("AND WHEN WETH price halves (Alices liquidity is 63k*0.6+1.5k*0.7=38850)", () => {
          beforeEach(async () => {
            await exactlyEnv.oracle.setPrice(fixedLenderETH.address, parseUnits("1500"));
          });

          it("THEN alice has a small (39900-38850 = 1050) liquidity shortfall", async () => {
            const [collateral, debt] = await auditor.accountLiquidity(alice.address, ethers.constants.AddressZero, 0);
            expect(debt.sub(collateral)).to.eq(parseUnits("1050"));
          });

          describe("AND WHEN a liquidator repays the max amount (19kDAI)", () => {
            let tx: any;
            beforeEach(async () => {
              tx = await fixedLenderDAI
                .connect(bob)
                .liquidate(alice.address, parseUnits("12250"), fixedLenderWBTC.address);
            });

            it("THEN alice no longer has a liquidity shortfall", async () => {
              const [collateral, debt] = await auditor.accountLiquidity(alice.address, ethers.constants.AddressZero, 0);
              expect(debt).to.lt(collateral);
            });

            it("AND the liquidator seized 19k + 10% = 13475 of collateral (WBTC)", async () => {
              // 13475usd of btc at its current price of 63kusd + 10% incentive for liquidator
              const seizedWBTC = parseUnits("21388890", 0);
              await expect(tx).to.emit(fixedLenderWBTC, "AssetSeized").withArgs(bob.address, alice.address, seizedWBTC);
            });

            it("AND she has some liquidity", async () => {
              const [collateral, debt] = await auditor.accountLiquidity(alice.address, ethers.constants.AddressZero, 0);
              const liquidity = collateral.sub(debt);
              expect(liquidity).to.be.gt(parseUnits("6177"));
              expect(liquidity).to.be.lt(parseUnits("6178"));
            });
          });
        });
      });

      describe("AND WHEN WBTC price halves (Alices liquidity is 32.5k*0.6+3k*0.7=21.6k)", () => {
        beforeEach(async () => {
          await exactlyEnv.oracle.setPrice(fixedLenderWBTC.address, parseUnits("32500"));
        });
        describe("the collateral can be entirely depleted and still have some debt left", () => {
          describe("WHEN depleting Alices WETH collateral", () => {
            beforeEach(async () => {
              await fixedLenderDAI.connect(bob).liquidate(alice.address, parseUnits("2727"), fixedLenderETH.address);
            });
            it("THEN theres nearly no WETH supplied by Alice", async () => {
              expect(await fixedLenderETH.maxWithdraw(alice.address)).to.be.lt(parseUnits("0.001"));
            });
            describe("AND WHEN liquidating $27500 of Alices WBTC collateral", () => {
              beforeEach(async () => {
                await fixedLenderDAI
                  .connect(bob)
                  .liquidate(alice.address, parseUnits("27500"), fixedLenderWBTC.address);
              });
              it("THEN liquidating the max amount (4500, half of the remaining debt) does not revert (it gets capped)", async () => {
                await expect(
                  fixedLenderDAI.connect(bob).liquidate(alice.address, parseUnits("4500"), fixedLenderETH.address),
                ).to.not.be.reverted;
              });
              describe("AND WHEN liquidating the rest of the collateral", () => {
                beforeEach(async () => {
                  await exactlyEnv.oracle.setPrice(fixedLenderETH.address, parseUnits("10"));
                  await fixedLenderDAI
                    .connect(bob)
                    .liquidate(alice.address, parseUnits("2045"), fixedLenderWBTC.address);
                });
                it("THEN Alice has zero WBTC deposited", async () => {
                  expect(await fixedLenderWBTC.maxWithdraw(alice.address)).to.be.lt(parseUnits("0.021", 8));
                });
                // now theres no incentive to liquidate those 258 dai
                it("AND alice still has some DAI debt", async () => {
                  expect(await fixedLenderDAI.getDebt(alice.address)).to.be.lt(parseUnits("258"));
                });
              });
            });
          });
        });

        it("THEN alices liquidity is zero", async () => {
          // We expect liquidity to be equal to zero
          const [collateral, debt] = await auditor.accountLiquidity(alice.address, ethers.constants.AddressZero, 0);
          expect(collateral.sub(debt)).to.be.lt("1");
        });
        it("AND alice has a big (18k) liquidity shortfall", async () => {
          const [collateral, debt] = await auditor.accountLiquidity(alice.address, ethers.constants.AddressZero, 0);
          expect(debt.sub(collateral)).to.eq(parseUnits("18300"));
        });

        it("AND trying to repay an amount of zero fails", async () => {
          // We try to get all the WETH we can
          // We expect trying to repay zero to fail
          await expect(
            fixedLenderDAI.connect(bob).liquidate(alice.address, 0, fixedLenderETH.address),
          ).to.be.revertedWith("ZeroRepay()");
        });

        it("AND the position cant be liquidated by the borrower", async () => {
          // We expect self liquidation to fail
          await expect(
            fixedLenderDAI.liquidate(alice.address, parseUnits("15000"), fixedLenderETH.address),
          ).to.be.revertedWith("SelfLiquidation()");
        });

        describe("GIVEN an insufficient allowance on the liquidator", () => {
          beforeEach(async () => {
            await dai.connect(bob).approve(fixedLenderDAI.address, parseUnits("1000"));
          });
          it("WHEN trying to liquidate, THEN it reverts with a ERC20 transfer error", async () => {
            // We expect liquidation to fail because trying to liquidate
            // and repay with an amount that the contract doesn't have enough allowance for bob
            await expect(
              fixedLenderDAI.connect(bob).liquidate(alice.address, parseUnits("15000"), fixedLenderETH.address),
            ).to.be.revertedWith("TRANSFER_FROM_FAILED");
          });
        });

        describe("Liquidation error cases", () => {
          it("WHEN trying to liquidate 39850 DAI for WETH (of which there is only 3000usd), THEN it doesn't revert because the max assets gets capped", async () => {
            await expect(
              fixedLenderDAI.connect(bob).liquidate(alice.address, parseUnits("10000"), fixedLenderETH.address),
            ).to.not.be.reverted;
          });
          it("WHEN trying to liquidate as much as possible, THEN it doesn't revert because the max assets gets capped", async () => {
            await expect(
              fixedLenderDAI.connect(bob).liquidate(alice.address, ethers.constants.MaxUint256, fixedLenderETH.address),
            ).to.not.be.reverted;
          });
          it("WHEN liquidating slightly more than the close factor(0.5), (20000 DAI), THEN it doesn't revert", async () => {
            await expect(
              fixedLenderDAI.connect(bob).liquidate(alice.address, parseUnits("20000"), fixedLenderWBTC.address),
            ).to.not.be.reverted;
          });
        });
        // TODO: I think this should eventually be 'a position can be wiped out
        // if its undercollateralized enough' kind of test suite
        describe("AND WHEN liquidating slightly less than the close factor (19000 DAI)", () => {
          let tx: any;
          beforeEach(async () => {
            tx = fixedLenderDAI.connect(bob).liquidate(alice.address, parseUnits("19000"), fixedLenderWBTC.address);
            await tx;
          });
          it("THEN roughly 19000 USD + 10% = 20900 of collateral (WBTC) is seized", async () => {
            // this is equivalent to 18999.9 USD, at the provided price of
            // 32500 + 10% liquidation incentive
            const seizedWBTC = parseUnits("64307693", 0);
            await expect(tx).to.emit(fixedLenderWBTC, "AssetSeized").withArgs(bob.address, alice.address, seizedWBTC);
            expect(await wbtc.balanceOf(bob.address)).to.eq(seizedWBTC);
          });
          it("AND 19000 DAI of debt is repaid (debt covered)", async () => {
            const bobDAIBalanceBefore = parseUnits("135000");
            await expect(tx)
              .to.emit(fixedLenderDAI, "RepayAtMaturity")
              .withArgs(nextPoolID, bob.address, alice.address, parseUnits("19000"), parseUnits("19000"));
            expect(await dai.balanceOf(bob.address)).to.eq(bobDAIBalanceBefore.sub(parseUnits("19000")));
          });
        });
      });
    });
  });

  describe("GIVEN john funds the WETH maturity pool and deposits collateral to the smart pool", () => {
    beforeEach(async () => {
      exactlyEnv.switchWallet(john);
      await eth.transfer(john.address, parseUnits("20"));
      // we add WETH liquidity to the maturity
      await exactlyEnv.depositMP("WETH", futurePools(1)[0].toNumber(), "1.25");
      await exactlyEnv.depositMP("WETH", futurePools(2)[1].toNumber(), "1.25");

      await exactlyEnv.depositSP("WETH", "10");
      await exactlyEnv.enterMarket("WETH");
    });
    describe("AND GIVEN alice deposits 10k DAI to the smart pool AND borrows USD8k worth of WETH (80% collateralization rate)", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.depositSP("DAI", "10000");
        await exactlyEnv.enterMarket("DAI");

        await exactlyEnv.borrowMP("WETH", futurePools(1)[0].toNumber(), "0.93");
        await exactlyEnv.borrowMP("WETH", futurePools(2)[1].toNumber(), "0.93");
      });
      describe("WHEN WETH price doubles AND john borrows 10k DAI from a maturity pool (all liquidity in smart pool)", () => {
        beforeEach(async () => {
          await exactlyEnv.oracle.setPrice(fixedLenderETH.address, parseUnits("8000"));
          exactlyEnv.switchWallet(john);
          await exactlyEnv.borrowMP("DAI", futurePools(1)[0].toNumber(), "10000");
        });
        it("THEN it reverts with error INSUFFICIENT_PROTOCOL_LIQUIDITY when trying to liquidate alice's positions", async () => {
          await eth.connect(john).approve(fixedLenderETH.address, parseUnits("1"));

          await expect(
            fixedLenderETH.connect(john).liquidate(alice.address, parseUnits("1"), fixedLenderDAI.address),
          ).to.be.revertedWith("InsufficientProtocolLiquidity()");
        });
        describe("AND GIVEN a DAI liquidity deposit to the smart pool", () => {
          beforeEach(async () => {
            exactlyEnv.switchWallet(john);
            await dai.mint(john.address, parseUnits("10000"));
            await exactlyEnv.depositSP("DAI", "10000");
            await eth.connect(john).approve(fixedLenderETH.address, parseUnits("1"));
          });
          it("WHEN both of alice's positions are liquidated THEN it doesn't revert", async () => {
            await expect(fixedLenderETH.connect(john).liquidate(alice.address, parseUnits("1"), fixedLenderDAI.address))
              .to.not.be.reverted;
          });
          it("AND WHEN trying to liquidate in a market where alice doesn't have borrows THEN it reverts", async () => {
            await expect(
              fixedLenderWBTC.connect(john).liquidate(alice.address, parseUnits("0.5"), fixedLenderDAI.address),
            ).to.be.reverted;
          });
        });
      });
    });
  });

  describe("GIVEN john funds the DAI maturity pool", () => {
    beforeEach(async () => {
      exactlyEnv.switchWallet(john);
      await dai.mint(john.address, parseUnits("10000"));
      // we add DAI liquidity to the maturities
      await exactlyEnv.depositMP("DAI", futurePools(1)[0].toNumber(), "1000");
      await exactlyEnv.depositMP("DAI", futurePools(2)[1].toNumber(), "6000");
    });
    describe("AND GIVEN alice deposits USD10k worth of WETH to the smart pool AND borrows 7k DAI (70% collateralization rate)", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.depositSP("WETH", "5");
        await exactlyEnv.enterMarket("WETH");

        await exactlyEnv.borrowMP("DAI", futurePools(1)[0].toNumber(), "1000");
        await exactlyEnv.borrowMP("DAI", futurePools(2)[1].toNumber(), "6000");
      });
      describe("WHEN 20 days goes by without payment, WETH price halves AND alice's first borrow is liquidated with a higher amount as repayment", () => {
        let johnETHBalanceBefore: any;
        let johnDAIBalanceBefore: any;
        beforeEach(async () => {
          await exactlyEnv.oracle.setPrice(fixedLenderETH.address, parseUnits("1500"));
          await exactlyEnv.moveInTimeAndMine(futurePools(1)[0].toNumber() + 86_400 * 20);
          johnETHBalanceBefore = await eth.balanceOf(john.address);
          johnDAIBalanceBefore = await dai.balanceOf(john.address);
          await dai.connect(john).approve(fixedLenderDAI.address, parseUnits("6400"));
          // for maturity pool 1 alice's debt (borrowed + penalties) is aprox 1400
          // in the liquidation we try repaying 6000 (aprox 2100 should be returned and not accounted to seize tokens)
          // total alice borrows are 7000 (+ 400 penalties), so for dynamic close factor max to repay is 6800
          await fixedLenderDAI.connect(john).liquidate(alice.address, parseUnits("6400"), fixedLenderETH.address);
        });
        it("THEN the liquidator does not seize more ETH tokens than it should", async () => {
          // if john liquidates and repays 6000 + 400 in penalties, then he should seize 4.26 ETH (1500 each) + liquidation incentive (10%)
          // 4.26 + 0.426 = 4.686 ETH
          const johnETHBalanceAfter = await eth.balanceOf(john.address);
          expect(johnETHBalanceBefore).to.not.equal(johnETHBalanceAfter);
          expect(johnETHBalanceAfter.sub(johnETHBalanceBefore)).to.be.gt(parseUnits("4.69"));
          expect(johnETHBalanceAfter.sub(johnETHBalanceBefore)).to.be.lt(parseUnits("4.70"));
        });
        it("THEN the liquidator doesn't receive back any DAI spare repayment amount", async () => {
          const johnDAIBalanceAfter = await dai.balanceOf(john.address);
          expect(johnDAIBalanceBefore).to.not.equal(johnDAIBalanceAfter);
          expect(johnDAIBalanceBefore.sub(johnDAIBalanceAfter)).to.be.eq(parseUnits("6400"));
        });
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
