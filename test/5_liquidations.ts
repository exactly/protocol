import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import { ExaTime } from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv } from "./defaultEnv";

describe("Liquidations", function () {
  let auditor: Contract;
  let exactlyEnv: DefaultEnv;
  let nextPoolID: number;
  const exaTime = new ExaTime();

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

    nextPoolID = exaTime.nextPoolID();

    // From alice to bob
    await dai.transfer(bob.address, parseUnits("200000"));
    await dai.transfer(john.address, parseUnits("10000"));
  });

  describe("GIVEN alice deposits USD63k worth of WBTC, USD3k worth of WETH (66k total), 63k*0.6+3k*0.7=39k liquidity AND bob deposits 65kDAI", () => {
    beforeEach(async () => {
      // we deposit Eth to the protocol
      await exactlyEnv.depositSP("WETH", "1");

      // we deposit WBTC to the protocol
      await exactlyEnv.depositSP("WBTC", "1");

      // bob deposits DAI to the protocol to have money in the pool
      exactlyEnv.switchWallet(bob);
      await exactlyEnv.depositMP("DAI", nextPoolID, "65000");
      await dai.connect(bob).approve(fixedLenderDAI.address, parseUnits("200000"));
      await dai.connect(john).approve(fixedLenderDAI.address, parseUnits("10000"));
    });

    describe("AND GIVEN Alice takes the biggest loan she can (39900 DAI)", () => {
      beforeEach(async () => {
        // we make WETH & WBTC count as collateral
        await auditor.enterMarkets([fixedLenderETH.address, fixedLenderWBTC.address]);

        // this works because 1USD (liquidity) = 1DAI (asset to borrow)
        amountToBorrowDAI = "39900";
        // alice borrows all liquidity
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.borrowMP("DAI", nextPoolID, amountToBorrowDAI);
      });

      describe("WHEN john supplies to the smart pool & the pool matures (prices stay the same) and 20 days goes by without payment", () => {
        beforeEach(async () => {
          exactlyEnv.switchWallet(john);
          await exactlyEnv.depositSP("DAI", "10000");
          await exactlyEnv.moveInTime(nextPoolID + exaTime.ONE_DAY * 20);
        });
        describe("Alice is a sneaky gal and uses a flash loan to recover her penalty", () => {
          describe("GIVEN a funded attacker contract and a flash-loaneable token", () => {
            let attacker: Contract;
            beforeEach(async () => {
              const attackerFactory = await ethers.getContractFactory("FlashLoanAttacker");
              attacker = await attackerFactory.deploy();
              await attacker.deployed();
              await dai.transfer(attacker.address, parseUnits("100000"));
            });
            it("WHEN alice takes a flash loan to make a big SP deposit AND repay her debt, THEN it reverts with a timelock error", async () => {
              await expect(attacker.attack(fixedLenderDAI.address, nextPoolID, amountToBorrowDAI)).to.be.revertedWith(
                "SmartPoolFundsLocked()",
              );
            });
          });
        });
        describe("AND the liquidation incentive is increased to 15%", () => {
          beforeEach(async () => {
            await auditor.setLiquidationIncentive(parseUnits("1.15"));
          });
          describe("AND the position is liquidated (19kdai)", () => {
            let tx: any;
            beforeEach(async () => {
              tx = fixedLenderDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("19000"),
                  parseUnits("19000"),
                  fixedLenderWBTC.address,
                  nextPoolID,
                );
              await tx;
            });
            it("THEN the liquidator seizes 19k+15% of collateral (in WBTC, 34682539 sats)", async () => {
              // 19kusd of btc at its current price of 63kusd + 15% incentive for liquidators
              const seizedWBTC = parseUnits("34682539", 0);

              await expect(tx).to.emit(fixedLenderWBTC, "SeizeAsset").withArgs(bob.address, alice.address, seizedWBTC);
            });
          });
        });

        describe("AND the position is liquidated a first time (19kdai)", () => {
          let tx: any;
          let balancePreBTC: BigNumber;
          beforeEach(async () => {
            balancePreBTC = await exactlyEnv.getUnderlying("WBTC").connect(bob).balanceOf(bob.address);
            tx = fixedLenderDAI
              .connect(bob)
              .liquidate(alice.address, parseUnits("19000"), parseUnits("19000"), fixedLenderWBTC.address, nextPoolID);
            await tx;
          });
          it("THEN the liquidator seizes 19k+10% of collateral (WBTC)", async () => {
            // 19000 USD of btc at its current price of 63000 USD + 10% incentive for liquidators
            const seizedWBTC = parseUnits("33174603", 0);
            await expect(tx).to.emit(fixedLenderWBTC, "SeizeAsset").withArgs(bob.address, alice.address, seizedWBTC);
          });

          it("THEN john DID collect the penalty fees because there's still SP debt", async () => {
            const johnBalanceEDAI = await exactlyEnv.getEToken("DAI").balanceOf(john.address);
            // John initial balance on the smart pool was 10000
            expect(johnBalanceEDAI).to.gt(parseUnits("15428"));
            expect(johnBalanceEDAI).to.lt(parseUnits("15429"));
          });

          it("THEN liquidator receives WBTC", async () => {
            // 19000 + 10% liquidation incentive = 20900 usd
            // 20900 USD / 63000 USD/BTC = 0.33174603 BTC (or 33174603*10^18)
            await tx;
            const receivedBTC = parseUnits("33174603", 0);
            const balancePostBTC = await exactlyEnv.getUnderlying("WBTC").connect(bob).balanceOf(bob.address);
            expect(balancePostBTC.sub(balancePreBTC)).to.equal(receivedBTC);
          });

          it("AND 19k DAI of debt has been repaid, making debt ~36860 DAI", async () => {
            const [, debt] = await fixedLenderDAI.getAccountSnapshot(alice.address, nextPoolID);

            // Borrowed is 39850
            const totalBorrowAmount = parseUnits("39900");

            // penalty is 2% * 20 days = 40/100 + 1 = 140/100
            // so amount owed is 55860
            const amountOwed = parseUnits("55860");
            const debtCovered = parseUnits("19000").mul(totalBorrowAmount).div(amountOwed);
            const newDebtCalculated = totalBorrowAmount.sub(debtCovered).mul(140).div(100);

            // debt should be approximately 36857
            expect(debt).to.be.closeTo(newDebtCalculated, 10000000000000);
          });

          describe("AND WHEN the position is liquidated a second time (55818-19000)/2 ~== 18000", () => {
            beforeEach(async () => {
              tx = fixedLenderDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("18000"),
                  parseUnits("18000"),
                  fixedLenderWBTC.address,
                  nextPoolID,
                );
              await tx;
            });
            it("THEN the liquidator seizes 18k+10% of collateral (WBTC)", async () => {
              // 10.4kusd of btc at its current price of 63kusd + 10% incentive for liquidators
              const seizedWBTC = parseUnits("31428570", 0);
              await expect(tx).to.emit(fixedLenderWBTC, "SeizeAsset").withArgs(bob.address, alice.address, seizedWBTC);
            });
            it("AND 18k DAI of debt has been repaid, making debt ~18k DAI", async () => {
              const [, debt] = await fixedLenderDAI.getAccountSnapshot(alice.address, nextPoolID);
              expect(debt).to.be.lt(parseUnits("19000"));
              expect(debt).to.be.gt(parseUnits("18000"));
            });
          });
        });
      });

      describe("A position can be recollateralized through liquidation", () => {
        describe("AND WHEN WETH price halves (Alices liquidity is 63k*0.6+1.5k*0.7=38850)", () => {
          beforeEach(async () => {
            await exactlyEnv.setOracleMockPrice("WETH", "1500");
          });

          it("THEN alice has a small (39900-38850 = 1050) liquidity shortfall", async () => {
            const shortfall = (await auditor.getAccountLiquidity(alice.address))[1];
            expect(shortfall).to.eq(parseUnits("1050"));
          });

          describe("AND WHEN a liquidator repays the max amount (19kDAI)", () => {
            let tx: any;
            beforeEach(async () => {
              tx = await fixedLenderDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("19000"),
                  parseUnits("19000"),
                  fixedLenderWBTC.address,
                  nextPoolID,
                );
            });

            it("THEN alice no longer has a liquidity shortfall", async () => {
              const shortfall = (await auditor.getAccountLiquidity(alice.address))[1];
              expect(shortfall).to.eq(0);
            });

            it("AND the liquidator seized 19k + 10% = 20900 of collateral (WBTC)", async () => {
              // 19kusd of btc at its current price of 63kusd + 10% incentive for liquidators
              const seizedWBTC = parseUnits("33174603", 0);
              await expect(tx).to.emit(fixedLenderWBTC, "SeizeAsset").withArgs(bob.address, alice.address, seizedWBTC);
            });

            // debt: 39900-19000 = 20900
            // liquidity: (1-0.33174603)*0.6*63000+1500*0.7 = 26310.000066000
            // 5410
            it("AND she has some liquidity", async () => {
              const liquidity = (await auditor.getAccountLiquidity(alice.address))[0];
              expect(liquidity).to.be.lt(parseUnits("5410.1"));
              expect(liquidity).to.be.gt(parseUnits("5410"));
            });
          });
        });
      });

      describe("AND WHEN WBTC price halves (Alices liquidity is 32.5k*0.6+3k*0.7=21.6k)", () => {
        beforeEach(async () => {
          await exactlyEnv.setOracleMockPrice("WBTC", "32500");
        });
        describe("the collateral can be entirely depleted and still have some debt left", () => {
          describe("WHEN depleting Alices WETH collateral", () => {
            beforeEach(async () => {
              await fixedLenderDAI.connect(bob).liquidate(
                alice.address,
                // maybe I should've used amounts divisible by each other
                parseUnits("2727"),
                parseUnits("2727"),
                fixedLenderETH.address,
                nextPoolID,
              );
            });
            it("THEN theres nearly no WETH supplied by Alice", async () => {
              const [depositedETH] = await fixedLenderETH.getAccountSnapshot(alice.address, nextPoolID);
              expect(depositedETH).to.be.lt(parseUnits("0.001"));
            });
            describe("AND WHEN liquidating $27500 of Alices WBTC collateral (two steps required)", () => {
              beforeEach(async () => {
                await fixedLenderDAI
                  .connect(bob)
                  .liquidate(
                    alice.address,
                    parseUnits("18000"),
                    parseUnits("18000"),
                    fixedLenderWBTC.address,
                    nextPoolID,
                  );
                await fixedLenderDAI
                  .connect(bob)
                  .liquidate(
                    alice.address,
                    parseUnits("9500"),
                    parseUnits("9500"),
                    fixedLenderWBTC.address,
                    nextPoolID,
                  );
              });
              it("THEN liquidating the max amount (4500, half of the remaining debt) is no longer possible", async () => {
                await expect(
                  fixedLenderDAI
                    .connect(bob)
                    .liquidate(
                      alice.address,
                      parseUnits("4500"),
                      parseUnits("4500"),
                      fixedLenderETH.address,
                      nextPoolID,
                    ),
                ).to.be.revertedWith("BalanceExceeded()");
              });
              describe("AND WHEN liquidating the rest of the collateral", () => {
                beforeEach(async () => {
                  await fixedLenderDAI
                    .connect(bob)
                    .liquidate(
                      alice.address,
                      parseUnits("2045"),
                      parseUnits("2045"),
                      fixedLenderWBTC.address,
                      nextPoolID,
                    );
                });
                it("THEN the Alice has zero WBTC deposited", async () => {
                  const [depositedWBTC] = await fixedLenderWBTC.getAccountSnapshot(alice.address, nextPoolID);
                  expect(depositedWBTC).to.be.lt(parseUnits("0.0005", 8));
                });
                // now theres no incentive to liquidate those 7500 dai
                it("AND alice still has some DAI debt", async () => {
                  const [, debt] = await fixedLenderDAI.getAccountSnapshot(alice.address, nextPoolID);
                  expect(debt).to.eq(parseUnits("7628"));
                });
              });
            });
          });
        });

        it("THEN alices liquidity is zero", async () => {
          // We expect liquidity to be equal to zero
          const liquidityAfterOracleChange = (await auditor.getAccountLiquidity(alice.address))[0];
          expect(liquidityAfterOracleChange).to.be.lt("1");
        });
        it("AND alice has a big (18k) liquidity shortfall", async () => {
          const shortfall = (await auditor.getAccountLiquidity(alice.address))[1];
          expect(shortfall).to.eq(parseUnits("18300"));
        });

        it("AND trying to repay an amount of zero fails", async () => {
          // We try to get all the WETH we can
          // We expect trying to repay zero to fail
          await expect(
            fixedLenderDAI.connect(bob).liquidate(alice.address, 0, 0, fixedLenderETH.address, nextPoolID),
          ).to.be.revertedWith("ZeroRepay()");
        });

        it("AND the position cant be liquidated by the borrower", async () => {
          // We expect self liquidation to fail
          await expect(
            fixedLenderDAI.liquidate(
              alice.address,
              parseUnits("15000"),
              parseUnits("15000"),
              fixedLenderETH.address,
              nextPoolID,
            ),
          ).to.be.revertedWith("LiquidatorNotBorrower()");
        });

        describe("GIVEN an insufficient allowance on the liquidator", () => {
          beforeEach(async () => {
            await dai.connect(bob).approve(fixedLenderDAI.address, parseUnits("10000"));
          });
          it("WHEN trying to liquidate, THEN it reverts with a ERC20 transfer error", async () => {
            // We expect liquidation to fail because trying to liquidate
            // and take over a collateral that bob doesn't have enough
            await expect(
              fixedLenderDAI
                .connect(bob)
                .liquidate(alice.address, parseUnits("15000"), parseUnits("15000"), fixedLenderETH.address, nextPoolID),
            ).to.be.revertedWith("ERC20");
          });
        });

        describe("Liquidation error cases", () => {
          it("WHEN trying to liquidate 39850 DAI for WETH (of which there is only 3000usd), THEN it reverts with a TOKENS_MORE_THAN_BALANCE error", async () => {
            // We expect liquidation to fail because trying to liquidate
            // and take over a collateral that bob doesn't have enough
            await expect(
              fixedLenderDAI
                .connect(bob)
                .liquidate(alice.address, parseUnits("10000"), parseUnits("10000"), fixedLenderETH.address, nextPoolID),
            ).to.be.revertedWith("BalanceExceeded()");
          });
          it("WHEN liquidating slightly more than the close factor(0.5), (20000 DAI), THEN it reverts", async () => {
            // We expect liquidation to fail because trying to liquidate too much (more than close factor of the borrowed asset)
            await expect(
              fixedLenderDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("20000"),
                  parseUnits("20000"),
                  fixedLenderWBTC.address,
                  nextPoolID,
                ),
            ).to.be.revertedWith("TooMuchRepay()");
          });
        });
        // TODO: I think this should eventually be 'a position can be wiped out
        // if its undercollateralized enough' kind of testsuite
        describe("AND WHEN liquidating slightly less than the close factor (19000 DAI)", () => {
          let tx: any;
          beforeEach(async () => {
            tx = fixedLenderDAI
              .connect(bob)
              .liquidate(alice.address, parseUnits("19000"), parseUnits("19000"), fixedLenderWBTC.address, nextPoolID);
            await tx;
          });
          it("THEN roughly 19000 USD + 10% = 20900 of collateral (WBTC) is seized", async () => {
            // this is equivalent to 18999.9 USD, at the provided price of
            // 32500 + 10% liquidation incentive
            const seizedWBTC = parseUnits("64307691", 0);
            await expect(tx).to.emit(fixedLenderWBTC, "SeizeAsset").withArgs(bob.address, alice.address, seizedWBTC);
            expect(await wbtc.balanceOf(bob.address)).to.eq(seizedWBTC);
          });
          it("AND 19000 DAI of debt is repaid (debt covered)", async () => {
            const bobDAIBalanceBefore = parseUnits("135000");
            await expect(tx)
              .to.emit(fixedLenderDAI, "RepayToMaturityPool")
              .withArgs(bob.address, alice.address, parseUnits("19000"), parseUnits("19000"), nextPoolID);
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
      await exactlyEnv.depositMP("WETH", exaTime.poolIDByNumberOfWeek(1), "1.25");
      await exactlyEnv.depositMP("WETH", exaTime.poolIDByNumberOfWeek(2), "1.25");

      await exactlyEnv.depositSP("WETH", "10");
      await exactlyEnv.enterMarkets(["WETH"]);
    });
    describe("AND GIVEN alice deposits 10k DAI to the smart pool AND borrows USD8k worth of WETH (80% collateralization rate)", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.depositSP("DAI", "10000");
        await exactlyEnv.enterMarkets(["DAI"]);

        await exactlyEnv.borrowMP("WETH", exaTime.poolIDByNumberOfWeek(1), "1.25");
        await exactlyEnv.borrowMP("WETH", exaTime.poolIDByNumberOfWeek(2), "1.25");
      });
      describe("WHEN WETH price doubles AND john borrows 10k DAI from a maturity pool (all liquidity in smart pool)", () => {
        beforeEach(async () => {
          await exactlyEnv.oracle.setPrice("WETH", parseUnits("8000"));
          // We borrow 10k DAI from 12 maturities since we can't borrow too much from the smart pool with only one maturity
          // We can't deposit DAI liquidity to a maturity as a workaround since we are trying to test a seize without underlying liquidity
          exactlyEnv.switchWallet(john);
          for (let i = 1; i < exaTime.MAX_POOLS + 1; i++) {
            await exactlyEnv.borrowMP("DAI", exaTime.poolIDByNumberOfWeek(i), "833.33");
          }
        });
        it("THEN it reverts with error INSUFFICIENT_PROTOCOL_LIQUIDITY when trying to liquidate one of alice's positions", async () => {
          await eth.connect(john).approve(fixedLenderETH.address, parseUnits("1"));

          await expect(
            fixedLenderETH
              .connect(john)
              .liquidate(alice.address, parseUnits("1"), parseUnits("1"), fixedLenderDAI.address, nextPoolID),
          ).to.be.revertedWith("InsufficientProtocolLiquidity()");
        });
        describe("AND GIVEN a DAI liquidity deposit to the smart pool", () => {
          beforeEach(async () => {
            exactlyEnv.switchWallet(john);
            await dai.transfer(john.address, parseUnits("10000"));
            await exactlyEnv.depositSP("DAI", "10000");
          });
          it("WHEN both of alice's positions are liquidated THEN it doesn't revert", async () => {
            await eth.connect(john).approve(fixedLenderETH.address, parseUnits("2"));

            await expect(
              fixedLenderETH
                .connect(john)
                .liquidate(
                  alice.address,
                  parseUnits("0.5"),
                  parseUnits("0.5"),
                  fixedLenderDAI.address,
                  exaTime.poolIDByNumberOfWeek(1),
                ),
            ).to.not.be.reverted;
            await expect(
              fixedLenderETH
                .connect(john)
                .liquidate(
                  alice.address,
                  parseUnits("0.5"),
                  parseUnits("0.5"),
                  fixedLenderDAI.address,
                  exaTime.poolIDByNumberOfWeek(2),
                ),
            ).to.not.be.reverted;
          });
        });
      });
    });
  });

  describe("GIVEN john funds the DAI maturity pool", () => {
    beforeEach(async () => {
      exactlyEnv.switchWallet(john);
      await dai.transfer(john.address, parseUnits("10000"));
      // we add DAI liquidity to the maturities
      await exactlyEnv.depositMP("DAI", exaTime.poolIDByNumberOfWeek(1), "1000");
      await exactlyEnv.depositMP("DAI", exaTime.poolIDByNumberOfWeek(2), "6000");
    });
    describe("AND GIVEN alice deposits USD10k worth of WETH to the smart pool AND borrows 7k DAI (70% collateralization rate)", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.depositSP("WETH", "3.35");
        await exactlyEnv.enterMarkets(["WETH"]);

        await exactlyEnv.borrowMP("DAI", exaTime.poolIDByNumberOfWeek(1), "1000");
        await exactlyEnv.borrowMP("DAI", exaTime.poolIDByNumberOfWeek(2), "6000");
      });
      describe("WHEN 20 days goes by without payment, WETH price halves AND alice's first borrow is liquidated with a higher amount as repayment", () => {
        let johnETHBalanceBefore: any;
        let johnDAIBalanceBefore: any;
        beforeEach(async () => {
          await exactlyEnv.oracle.setPrice("WETH", parseUnits("1500"));
          await exactlyEnv.moveInTimeAndMine(exaTime.poolIDByNumberOfWeek(1) + exaTime.ONE_DAY * 20);
          johnETHBalanceBefore = await eth.balanceOf(john.address);
          johnDAIBalanceBefore = await dai.balanceOf(john.address);
          await dai.connect(john).approve(fixedLenderDAI.address, parseUnits("3000"));
          // maria's debt (borrowed + penalties) is aprox 1400 for maturity pool 1
          // in the liquidation we repay 3000 (aprox 1600 should be returned and not accounted to seize tokens)
          await fixedLenderDAI
            .connect(john)
            .liquidate(
              alice.address,
              parseUnits("3000"),
              parseUnits("3000"),
              fixedLenderETH.address,
              exaTime.poolIDByNumberOfWeek(1),
            );
        });
        it("THEN the liquidator does not seize more ETH tokens than it should", async () => {
          // if john liquidates and repays 3000, then he should seize 2 ETH (1500 each) + liquidation incentive (10%)
          // 2 + 0.2 = 2.2 ETH
          // but if john ACTUALLY repays approx 1400, then he seizes almost 1 ETH + liquidation incentive (10%)
          // 0.93 + 0.093 = 1.023000 ETH
          const johnETHBalanceAfter = await eth.balanceOf(john.address);
          expect(johnETHBalanceBefore).to.not.equal(johnETHBalanceAfter);
          expect(johnETHBalanceAfter).to.be.gt(parseUnits("1.02"));
          expect(johnETHBalanceAfter).to.be.lt(parseUnits("1.03"));
        });
        it("THEN the liquidator receives back any DAI spare repayment amount", async () => {
          // liquidator tried to repay 3000 but only spent approx 1400 (total owed by maria)
          const johnDAIBalanceAfter = await dai.balanceOf(john.address);
          expect(johnDAIBalanceBefore).to.not.equal(johnDAIBalanceAfter);
          expect(johnDAIBalanceAfter).to.be.lt(johnDAIBalanceBefore.sub(parseUnits("1400")));
          expect(johnDAIBalanceAfter).to.be.gt(johnDAIBalanceBefore.sub(parseUnits("1401")));
        });
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
