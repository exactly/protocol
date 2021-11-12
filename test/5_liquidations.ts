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
} from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Liquidations", function () {
  let auditor: Contract;
  let exactlyEnv: DefaultEnv;
  let nextPoolID = new ExaTime().nextPoolID();

  let bob: SignerWithAddress;
  let alice: SignerWithAddress;

  let exafinETH: Contract;
  let eth: Contract;
  let exafinDAI: Contract;
  let dai: Contract;
  let exafinWBTC: Contract;
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

    exafinETH = exactlyEnv.getFixedLender("ETH");
    eth = exactlyEnv.getUnderlying("ETH");
    exafinDAI = exactlyEnv.getFixedLender("DAI");
    dai = exactlyEnv.getUnderlying("DAI");
    exafinWBTC = exactlyEnv.getFixedLender("WBTC");
    wbtc = exactlyEnv.getUnderlying("WBTC");

    // From alice to bob
    await dai.transfer(bob.address, parseUnits("100000"));
  });

  describe("GIVEN alice supplies USD63k worth of WBTC, USD3k worth of ETH (66k total), 63k*0.6+3k*0.7=39k liquidity AND bob supplies 65kDAI", () => {
    beforeEach(async () => {
      // we supply Eth to the protocol
      const amountETH = parseUnits("1");
      await eth.approve(exafinETH.address, amountETH);
      await exafinETH.supply(alice.address, amountETH, nextPoolID);

      // we supply WBTC to the protocol
      const amountWBTC = parseUnits("1", 8);
      await wbtc.approve(exafinWBTC.address, amountWBTC);
      await exafinWBTC.supply(alice.address, amountWBTC, nextPoolID);

      // bob supplies DAI to the protocol to have money in the pool
      const amountDAI = parseUnits("65000");
      await dai.connect(bob).approve(exafinDAI.address, amountDAI);
      await exafinDAI.connect(bob).supply(bob.address, amountDAI, nextPoolID);
      await dai.connect(bob).approve(exafinDAI.address, parseUnits("100000"));
    });

    describe("AND GIVEN Alice takes the biggest loan she can (39850 DAI), 50 buffer for interest", () => {
      beforeEach(async () => {
        // we make ETH & WBTC count as collateral
        await auditor.enterMarkets(
          [exafinETH.address, exafinWBTC.address],
          nextPoolID
        );
        // this works because 1USD (liquidity) = 1DAI (asset to borrow)
        amountToBorrowDAI = parseUnits("39850");

        // alice borrows all liquidity
        await exafinDAI.borrow(amountToBorrowDAI, nextPoolID);
      });

      describe("WHEN the pool matures (prices stay the same)", () => {
        beforeEach(async () => {
          await ethers.provider.send("evm_setNextBlockTimestamp", [nextPoolID]);
          await ethers.provider.send("evm_mine", []);
        });
        it("THEN the position is liquidateable", async () => {
          const tx = exafinDAI
            .connect(bob)
            .liquidate(
              alice.address,
              parseUnits("15000"),
              exafinWBTC.address,
              nextPoolID
            );
          await expect(tx).to.not.be.reverted;
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
              tx = await exafinDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("19000"),
                  exafinWBTC.address,
                  nextPoolID
                );
            });
            it("THEN alice no longer has a liquidity shortfall", async () => {
              const shortfall = (
                await auditor.getAccountLiquidity(alice.address, nextPoolID)
              )[1];
              expect(shortfall).to.eq(0);
            });
            it("AND the liquidator seized 19k of collateral (WBTC)", async () => {
              // FIXME the liquidator should get a price better than market
              // 19kusd of btc at its current price of 63kusd
              const seizedWBTC = parseUnits("30158730", 0);
              await expect(tx)
                .to.emit(exafinWBTC, "Seized")
                .withArgs(bob.address, alice.address, seizedWBTC, nextPoolID);
            });
            // debt: 39850-19000 = 20850
            // liquidity: (1-.30158730)*0.6*63000+1500*0.7 = 27450
            // 27450- 20850= 6600
            it("AND she has some liquidity", async () => {
              const liquidity = (
                await auditor.getAccountLiquidity(alice.address, nextPoolID)
              )[0];
              expect(liquidity).to.be.gt(parseUnits("6500"));
              expect(liquidity).to.be.lt(parseUnits("6600"));
            });
          });
        });
      });

      describe("AND WHEN WBTC price halves (Alices liquidity is 32.5k*0.6+3k*0.7=21.6k)", () => {
        beforeEach(async () => {
          await exactlyEnv.setOracleMockPrice("WBTC", "32500");
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
            exafinDAI.liquidate(alice.address, 0, exafinETH.address, nextPoolID)
          ).to.be.revertedWith(errorGeneric(ProtocolError.REPAY_ZERO));
        });
        it("AND the position cant be liquidated by the borrower", async () => {
          // We expect self liquidation to fail
          await expect(
            exafinDAI.liquidate(
              alice.address,
              parseUnits("15000"),
              exafinETH.address,
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
              .approve(exafinDAI.address, parseUnits("10000"));
          });
          it("WHEN trying to liquidate, THEN it reverts with a ERC20 transfer error", async () => {
            // We expect liquidation to fail because trying to liquidate
            // and take over a collateral that bob doesn't have enough
            await expect(
              exafinDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("15000"),
                  exafinETH.address,
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
              exafinDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("10000"),
                  exafinETH.address,
                  nextPoolID
                )
            ).to.be.revertedWith(
              errorGeneric(ProtocolError.TOKENS_MORE_THAN_BALANCE)
            );
          });
          it("WHEN liquidating slightly more than the close factor(0.5), (20000 DAI), THEN it reverts", async () => {
            // We expect liquidation to fail because trying to liquidate too much (more than close factor of the borrowed asset)
            await expect(
              exafinDAI
                .connect(bob)
                .liquidate(
                  alice.address,
                  parseUnits("20000"),
                  exafinWBTC.address,
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
            tx = exafinDAI
              .connect(bob)
              .liquidate(
                alice.address,
                parseUnits("19000"),
                exafinWBTC.address,
                nextPoolID
              );
            await tx;
          });
          // FIXME: this shouldn't work like this, the liquidation should be
          // at a slightly better than market price
          it("THEN roughly 19000 USD of collateral (WBTC) is seized", async () => {
            const protocolShare = parseUnits("0.028");
            // this is equivalent to 18999.9 USD, at the provided price of 32500
            const seizedWBTC = parseUnits("58461538", 0);
            await expect(tx)
              .to.emit(exafinWBTC, "Seized")
              .withArgs(bob.address, alice.address, seizedWBTC, nextPoolID);
            const fee = seizedWBTC.mul(protocolShare).div(parseUnits("1"));
            // note that the liquidator is actually being paid 2.8% less (!!)
            // than market rate
            expect(await wbtc.balanceOf(bob.address)).to.eq(
              seizedWBTC.sub(fee)
            );
          });
          it("AND 19000 DAI of debt is repaid", async () => {
            const bobDAIBalanceBefore = parseUnits("35000");
            await expect(tx)
              .to.emit(exafinDAI, "Repaid")
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
