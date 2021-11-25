import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { BigNumber, Contract } from "ethers";
import {
  ProtocolError,
  ExactlyEnv,
  ExaTime,
  errorGeneric,
  DefaultEnv,
  parseBorrowEvent,
} from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Liquidations", function () {
  let auditor: Contract;
  let exactlyEnv: DefaultEnv;
  let nextPoolID: number;
  let exaTime = new ExaTime();

  let bob: SignerWithAddress;
  let alice: SignerWithAddress;

  let fixedLenderETH: Contract;
  let eth: Contract;
  let fixedLenderDAI: Contract;
  let dai: Contract;
  let fixedLenderWBTC: Contract;
  let wbtc: Contract;

  let mockedTokens = new Map([
    [
      "DAI",
      {
        decimals: 18,
        collateralRate: parseUnits("0.8"),
        usdPrice: parseUnits("1"),
      },
    ],
    [
      "ETH",
      {
        decimals: 18,
        collateralRate: parseUnits("0.7"),
        usdPrice: parseUnits("3000"),
      },
    ],
    [
      "WBTC",
      {
        decimals: 8,
        collateralRate: parseUnits("0.6"),
        usdPrice: parseUnits("63000"),
      },
    ],
  ]);

  let amountToBorrowDAI: BigNumber;

  let snapshot: any;
  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    [alice, bob] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(mockedTokens);
    auditor = exactlyEnv.auditor;

    fixedLenderETH = exactlyEnv.getFixedLender("ETH");
    eth = exactlyEnv.getUnderlying("ETH");
    fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    dai = exactlyEnv.getUnderlying("DAI");
    fixedLenderWBTC = exactlyEnv.getFixedLender("WBTC");
    wbtc = exactlyEnv.getUnderlying("WBTC");

    nextPoolID = exaTime.nextPoolID();

    // From alice to bob
    await dai.transfer(bob.address, parseUnits("200000"));
  });

  describe("GIVEN alice supplies USD63k worth of WBTC, USD3k worth of ETH (66k total), 63k*0.6+3k*0.7=39k liquidity AND bob supplies 65kDAI", () => {
    let txBorrowAliceDAI: any;
    beforeEach(async () => {
      // we supply Eth to the protocol
      const amountETH = parseUnits("1");
      await eth.approve(fixedLenderETH.address, amountETH);
      await fixedLenderETH.supply(alice.address, amountETH, nextPoolID);

      // we supply WBTC to the protocol
      const amountWBTC = parseUnits("1", 8);
      await wbtc.approve(fixedLenderWBTC.address, amountWBTC);
      await fixedLenderWBTC.supply(alice.address, amountWBTC, nextPoolID);

      // bob supplies DAI to the protocol to have money in the pool
      const amountDAI = parseUnits("65000");
      await dai.connect(bob).approve(fixedLenderDAI.address, amountDAI);
      await fixedLenderDAI
        .connect(bob)
        .supply(bob.address, amountDAI, nextPoolID);
      await dai
        .connect(bob)
        .approve(fixedLenderDAI.address, parseUnits("200000"));
    });

    describe("AND GIVEN Alice takes the biggest loan she can (39850 DAI), 50 buffer for interest", () => {
      beforeEach(async () => {
        // we make ETH & WBTC count as collateral
        await auditor.enterMarkets(
          [fixedLenderETH.address, fixedLenderWBTC.address],
          nextPoolID
        );
        // this works because 1USD (liquidity) = 1DAI (asset to borrow)
        amountToBorrowDAI = parseUnits("39850");

        // alice borrows all liquidity
        txBorrowAliceDAI = await fixedLenderDAI.borrow(
          amountToBorrowDAI,
          nextPoolID
        );
      });

      describe("WHEN the pool matures (prices stay the same) and 20 days goes by without payment", () => {
        beforeEach(async () => {
          await ethers.provider.send("evm_setNextBlockTimestamp", [
            nextPoolID + exaTime.ONE_DAY * 20 + exaTime.ONE_HOUR * 10,
          ]);
          await ethers.provider.send("evm_mine", []);
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
                  fixedLenderWBTC.address,
                  nextPoolID
                );
              await tx;
            });
            it("THEN the liquidator seizes 19k+15% of collateral (in WBTC, 34682539 sats)", async () => {
              // 19kusd of btc at its current price of 63kusd + 15% incentive for liquidators
              const seizedWBTC = parseUnits("34682539", 0);

              await expect(tx)
                .to.emit(fixedLenderWBTC, "Seized")
                .withArgs(bob.address, alice.address, seizedWBTC, nextPoolID);
            });
            it("AND 0.028% in fee is charged (971111 sats)", async () => {
              const seizedWBTC = parseUnits("34682539", 0);
              const protocolShare = parseUnits("0.028");
              const fee = seizedWBTC.mul(protocolShare).div(parseUnits("1"));
              expect(await wbtc.balanceOf(bob.address)).to.eq(
                seizedWBTC.sub(fee)
              );
              await expect(tx)
                .to.emit(fixedLenderWBTC, "ReservesAdded")
                .withArgs(fixedLenderWBTC.address, fee);
            });
          });
        });

        describe("AND the protcol fee is increased to 4%", () => {
          beforeEach(async () => {
            await fixedLenderWBTC.setLiquidationFee(parseUnits("0.04"));
          });
          describe("AND the position is liquidated (19kdai)", () => {
            let tx: any;
            beforeEach(async () => {
              tx = fixedLenderDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("19000"),
                  fixedLenderWBTC.address,
                  nextPoolID
                );
              await tx;
            });
            it("THEN the liquidator seizes 19k+10% of collateral (WBTC)", async () => {
              // 19kusd of btc at its current price of 63kusd + 10% incentive for liquidators
              const seizedWBTC = parseUnits("33174603", 0);

              await expect(tx)
                .to.emit(fixedLenderWBTC, "Seized")
                .withArgs(bob.address, alice.address, seizedWBTC, nextPoolID);
            });
            it("AND 0.4% in fee is charged (1326984 sats)", async () => {
              const seizedWBTC = parseUnits("33174603", 0);
              const protocolShare = parseUnits("0.04");
              const fee = seizedWBTC.mul(protocolShare).div(parseUnits("1"));
              expect(await wbtc.balanceOf(bob.address)).to.eq(
                seizedWBTC.sub(fee)
              );
              await expect(tx)
                .to.emit(fixedLenderWBTC, "ReservesAdded")
                .withArgs(fixedLenderWBTC.address, fee);
            });
          });
        });

        describe("AND the position is liquidated a first time (19kdai)", () => {
          let tx: any;
          beforeEach(async () => {
            tx = fixedLenderDAI
              .connect(bob)
              .liquidate(
                alice.address,
                parseUnits("19000"),
                fixedLenderWBTC.address,
                nextPoolID
              );
            await tx;
          });
          it("THEN the liquidator seizes 19k+10% of collateral (WBTC)", async () => {
            // 19kusd of btc at its current price of 63kusd + 10% incentive for liquidators
            const seizedWBTC = parseUnits("33174603", 0);
            await expect(tx)
              .to.emit(fixedLenderWBTC, "Seized")
              .withArgs(bob.address, alice.address, seizedWBTC, nextPoolID);
          });
          it("AND 19k DAI of debt has been repaid, making debt ~36818 DAI", async () => {
            const [, debt] = await fixedLenderDAI.getAccountSnapshot(
              alice.address,
              nextPoolID
            );
            const borrowEventDAI = await parseBorrowEvent(txBorrowAliceDAI);
            const totalBorrowAmount = borrowEventDAI.amount.add(
              borrowEventDAI.commission
            );

            // 2% * 20 days = 40/100 + 1 = 140/100
            const amountOwed = totalBorrowAmount.mul(140).div(100);
            const debtCovered = parseUnits("19000")
              .mul(totalBorrowAmount)
              .div(amountOwed);
            // remaining debt + 2% * 20 days = 40/100 + 1 = 140/100
            const newDebtCalculated = totalBorrowAmount
              .sub(debtCovered)
              .mul(140)
              .div(100);

            expect(debt).to.be.closeTo(newDebtCalculated, 10000);
          });
          describe("AND WHEN the position is liquidated a second time (55818-19000)/2 ~== 18000", () => {
            beforeEach(async () => {
              tx = fixedLenderDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("18000"),
                  fixedLenderWBTC.address,
                  nextPoolID
                );
              await tx;
            });
            it("THEN the liquidator seizes 18k+10% of collateral (WBTC)", async () => {
              // 10.4kusd of btc at its current price of 63kusd + 10% incentive for liquidators
              const seizedWBTC = parseUnits("31428570", 0);
              await expect(tx)
                .to.emit(fixedLenderWBTC, "Seized")
                .withArgs(bob.address, alice.address, seizedWBTC, nextPoolID);
            });
            it("AND 18k DAI of debt has been repaid, making debt ~10k DAI", async () => {
              const [, debt] = await fixedLenderDAI.getAccountSnapshot(
                alice.address,
                nextPoolID
              );
              expect(debt).to.be.lt(parseUnits("19000"));
              expect(debt).to.be.gt(parseUnits("18000"));
            });
          });
        });
      });

      describe("A position can be recollateralized through liquidation", () => {
        describe("AND WHEN ETH price halves (Alices liquidity is 63k*0.6+1.5k*0.7=38850)", () => {
          beforeEach(async () => {
            await exactlyEnv.setOracleMockPrice("ETH", "1500");
          });
          it("THEN alice has a small (1k) liquidity shortfall", async () => {
            let shortfall = (
              await auditor.getAccountLiquidity(alice.address, nextPoolID)
            )[1];
            expect(shortfall).to.be.gt(parseUnits("1000"));
            expect(shortfall).to.be.lt(parseUnits("1100"));
          });
          // The liquidator has an incentive to repay as much of the debt as
          // possible (assuming he has an incentive to repay the debt in the
          // first place, see below), since _as soon as the position is
          // undercollateralized_, liquidators can repay half of its debt,
          // regardless of the user's shortfall
          describe("AND WHEN a liquidator repays the max amount (19kDAI)", () => {
            let tx: any;
            beforeEach(async () => {
              tx = await fixedLenderDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("19000"),
                  fixedLenderWBTC.address,
                  nextPoolID
                );
            });
            it("THEN alice no longer has a liquidity shortfall", async () => {
              const shortfall = (
                await auditor.getAccountLiquidity(alice.address, nextPoolID)
              )[1];
              expect(shortfall).to.eq(0);
            });
            it("AND the liquidator seized 19k + 10% = 20900 of collateral (WBTC)", async () => {
              // 19kusd of btc at its current price of 63kusd + 10% incentive for liquidators
              const seizedWBTC = parseUnits("33174603", 0);
              await expect(tx)
                .to.emit(fixedLenderWBTC, "Seized")
                .withArgs(bob.address, alice.address, seizedWBTC, nextPoolID);
            });
            // debt: 39850-19000 = 20850
            // liquidity: (1-.30158730)*0.6*63000+1500*0.7 = 27450
            // 27450- 20850= 6600
            it("AND she has some liquidity", async () => {
              const liquidity = (
                await auditor.getAccountLiquidity(alice.address, nextPoolID)
              )[0];
              expect(liquidity).to.be.gt(parseUnits("5400"));
              expect(liquidity).to.be.lt(parseUnits("5600"));
            });
          });
        });
      });

      describe("AND WHEN WBTC price halves (Alices liquidity is 32.5k*0.6+3k*0.7=21.6k)", () => {
        beforeEach(async () => {
          await exactlyEnv.setOracleMockPrice("WBTC", "32500");
        });
        describe("the collateral can be entirely depleted and still have some debt left", () => {
          describe("WHEN depleting Alices ETH collateral", () => {
            beforeEach(async () => {
              await fixedLenderDAI.connect(bob).liquidate(
                alice.address,
                // maybe I should've used amounts divisible by each other
                parseUnits("2727"),
                fixedLenderETH.address,
                nextPoolID
              );
            });
            it("THEN theres nearly no ETH supplied by Alice", async () => {
              const [suppliedETH] = await fixedLenderETH.getAccountSnapshot(
                alice.address,
                nextPoolID
              );
              expect(suppliedETH).to.be.lt(parseUnits("0.001"));
            });
            describe("AND WHEN liquidating $27500 of Alices WBTC collateral (two steps required)", () => {
              beforeEach(async () => {
                await fixedLenderDAI
                  .connect(bob)
                  .liquidate(
                    alice.address,
                    parseUnits("18000"),
                    fixedLenderWBTC.address,
                    nextPoolID
                  );
                await fixedLenderDAI
                  .connect(bob)
                  .liquidate(
                    alice.address,
                    parseUnits("9500"),
                    fixedLenderWBTC.address,
                    nextPoolID
                  );
              });
              it("THEN liquidating the max amount (4500, half of the remaining debt) is no longer possible", async () => {
                await expect(
                  fixedLenderDAI
                    .connect(bob)
                    .liquidate(
                      alice.address,
                      parseUnits("4500"),
                      fixedLenderETH.address,
                      nextPoolID
                    )
                ).to.be.revertedWith(
                  errorGeneric(ProtocolError.TOKENS_MORE_THAN_BALANCE)
                );
              });
              describe("AND WHEN liquidating the rest of the collateral", () => {
                beforeEach(async () => {
                  await fixedLenderDAI
                    .connect(bob)
                    .liquidate(
                      alice.address,
                      parseUnits("2045"),
                      fixedLenderWBTC.address,
                      nextPoolID
                    );
                });
                it("THEN the Alice has zero WBTC deposited", async () => {
                  const [suppliedWBTC] =
                    await fixedLenderWBTC.getAccountSnapshot(
                      alice.address,
                      nextPoolID
                    );
                  expect(suppliedWBTC).to.be.lt(parseUnits("0.0005", 8));
                });
                // now theres no incentive to liquidate those 7500 dai
                it("AND alice still has some DAI debt", async () => {
                  const [, debt] = await fixedLenderDAI.getAccountSnapshot(
                    alice.address,
                    nextPoolID
                  );
                  expect(debt).to.be.gt(parseUnits("7500"));
                });
              });
            });
          });
        });

        it("THEN alices liquidity is zero", async () => {
          // We expect liquidity to be equal to zero
          let liquidityAfterOracleChange = (
            await auditor.getAccountLiquidity(alice.address, nextPoolID)
          )[0];
          expect(liquidityAfterOracleChange).to.be.lt("1");
        });
        it("AND alice has a big (18k) liquidity shortfall", async () => {
          let shortfall = (
            await auditor.getAccountLiquidity(alice.address, nextPoolID)
          )[1];
          expect(shortfall).to.be.gt(parseUnits("18000"));
        });
        it("AND trying to repay an amount of zero fails", async () => {
          // We try to get all the ETH we can
          // We expect trying to repay zero to fail
          await expect(
            fixedLenderDAI.liquidate(
              alice.address,
              0,
              fixedLenderETH.address,
              nextPoolID
            )
          ).to.be.revertedWith(errorGeneric(ProtocolError.REPAY_ZERO));
        });
        it("AND the position cant be liquidated by the borrower", async () => {
          // We expect self liquidation to fail
          await expect(
            fixedLenderDAI.liquidate(
              alice.address,
              parseUnits("15000"),
              fixedLenderETH.address,
              nextPoolID
            )
          ).to.be.revertedWith(
            errorGeneric(ProtocolError.LIQUIDATOR_NOT_BORROWER)
          );
        });

        describe("GIVEN an insufficient allowance on the liquidator", () => {
          beforeEach(async () => {
            await dai
              .connect(bob)
              .approve(fixedLenderDAI.address, parseUnits("10000"));
          });
          it("WHEN trying to liquidate, THEN it reverts with a ERC20 transfer error", async () => {
            // We expect liquidation to fail because trying to liquidate
            // and take over a collateral that bob doesn't have enough
            await expect(
              fixedLenderDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("15000"),
                  fixedLenderETH.address,
                  nextPoolID
                )
            ).to.be.revertedWith("ERC20");
          });
        });

        describe("Liquidation error cases", () => {
          it("WHEN trying to liquidate 39850 DAI for ETH (of which there is only 3000usd), THEN it reverts with a TOKENS_MORE_THAN_BALANCE error", async () => {
            // We expect liquidation to fail because trying to liquidate
            // and take over a collateral that bob doesn't have enough
            await expect(
              fixedLenderDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("10000"),
                  fixedLenderETH.address,
                  nextPoolID
                )
            ).to.be.revertedWith(
              errorGeneric(ProtocolError.TOKENS_MORE_THAN_BALANCE)
            );
          });
          it("WHEN liquidating slightly more than the close factor(0.5), (20000 DAI), THEN it reverts", async () => {
            // We expect liquidation to fail because trying to liquidate too much (more than close factor of the borrowed asset)
            await expect(
              fixedLenderDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("20000"),
                  fixedLenderWBTC.address,
                  nextPoolID
                )
            ).to.be.revertedWith(errorGeneric(ProtocolError.TOO_MUCH_REPAY));
          });
        });
        // TODO: I think this should eventually be 'a position can be wiped out
        // if its undercollateralized enough' kind of testsuite
        describe("AND WHEN liquidating slightly less than the close factor (19000 DAI)", () => {
          let tx: any;
          beforeEach(async () => {
            tx = fixedLenderDAI
              .connect(bob)
              .liquidate(
                alice.address,
                parseUnits("19000"),
                fixedLenderWBTC.address,
                nextPoolID
              );
            await tx;
          });
          it("THEN roughly 19000 USD + 10% = 20900 of collateral (WBTC) is seized", async () => {
            const protocolShare = parseUnits("0.028");
            // this is equivalent to 18999.9 USD, at the provided price of
            // 32500 + 10% liquidation incentive
            const seizedWBTC = parseUnits("64307691", 0);
            await expect(tx)
              .to.emit(fixedLenderWBTC, "Seized")
              .withArgs(bob.address, alice.address, seizedWBTC, nextPoolID);
            const fee = seizedWBTC.mul(protocolShare).div(parseUnits("1"));
            expect(await wbtc.balanceOf(bob.address)).to.eq(
              seizedWBTC.sub(fee)
            );
          });
          it("AND 19000 DAI of debt is repaid", async () => {
            const bobDAIBalanceBefore = parseUnits("135000");
            await expect(tx)
              .to.emit(fixedLenderDAI, "RepaidLiquidate")
              .withArgs(
                bob.address,
                alice.address,
                parseUnits("19000"),
                nextPoolID
              );
            expect(await dai.balanceOf(bob.address)).to.eq(
              bobDAIBalanceBefore.sub(parseUnits("19000"))
            );
          });
        });
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
