import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import {
  ProtocolError,
  ExactlyEnv,
  ExaTime,
  errorGeneric,
} from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv } from "./defaultEnv";

describe("Liquidity computations", function () {
  let auditor: Contract;
  let exactlyEnv: DefaultEnv;
  let nextPoolID = new ExaTime().nextPoolID();

  let bob: SignerWithAddress;
  let laura: SignerWithAddress;

  let fixedLenderDAI: Contract;
  let dai: Contract;
  let fixedLenderUSDC: Contract;
  let usdc: Contract;
  let fixedLenderWBTC: Contract;
  let wbtc: Contract;

  let snapshot: any;
  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    // the owner deploys the contracts
    // bob the borrower
    // laura the lender
    [bob, laura] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create({});
    auditor = exactlyEnv.auditor;

    fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    dai = exactlyEnv.getUnderlying("DAI");
    fixedLenderUSDC = exactlyEnv.getFixedLender("USDC");
    usdc = exactlyEnv.getUnderlying("USDC");
    wbtc = exactlyEnv.getUnderlying("WBTC");

    await exactlyEnv.getInterestRateModel().setPenaltyRate(parseUnits("0.02"));

    // TODO: perhaps pass the addresses to ExactlyEnv.create and do all the
    // transfers in the same place?
    // wbtc laura will provide liquidity on
    await wbtc.transfer(laura.address, parseUnits("90000", 8));
    await usdc.transfer(laura.address, parseUnits("5", 6));
    await dai.transfer(laura.address, parseUnits("100000"));
    // dai & usdc bob will use as collateral
    await dai.transfer(bob.address, parseUnits("100000"));
    await usdc.transfer(bob.address, parseUnits("100000", 6));
    // we make DAI & USDC count as collateral
    await auditor.enterMarkets([
      fixedLenderDAI.address,
      fixedLenderUSDC.address,
    ]);
    await auditor
      .connect(laura)
      .enterMarkets([fixedLenderDAI.address, fixedLenderUSDC.address]);
  });

  describe("positions arent immediately liquidateable", () => {
    describe("GIVEN laura deposits 1kdai to a smart pool", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(laura);
        await exactlyEnv.depositSP("DAI", "1000");
      });

      it("THEN lauras liquidity is collateralRate*collateral -  0.8*1000 == 800, AND she has no shortfall", async () => {
        const [liquidity, shortfall] = await auditor.getAccountLiquidity(
          laura.address
        );

        expect(liquidity).to.be.eq(parseUnits("800"));
        expect(shortfall).to.be.eq(parseUnits("0"));
      });
      // TODO: a test where the supply interest is != 0, see if there's an error like the one described in this commit
      it("AND she has zero debt and is owed 1000DAI", async () => {
        const [supplied, owed] = await fixedLenderDAI.getAccountSnapshot(
          laura.address,
          nextPoolID
        );
        expect(supplied).to.be.eq(parseUnits("1000"));
        expect(owed).to.be.eq(parseUnits("0"));
      });
      describe("AND GIVEN a 1% borrow interest rate", () => {
        beforeEach(async () => {
          await exactlyEnv
            .getInterestRateModel()
            .setBorrowRate(parseUnits("0.01"));
        });
        it("AND WHEN laura asks for a 800 DAI loan, THEN it reverts because the interests make the owed amount larger than liquidity", async () => {
          await expect(
            exactlyEnv.borrowMP("DAI", nextPoolID, "800")
          ).to.be.revertedWith(
            errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY)
          );
        });
      });

      describe("AND WHEN laura asks for a 800 DAI loan", () => {
        beforeEach(async () => {
          await exactlyEnv.borrowMP("DAI", nextPoolID, "800");
        });
        it("THEN lauras liquidity is zero, AND she has no shortfall", async () => {
          const [liquidity, shortfall] = await auditor.getAccountLiquidity(
            laura.address
          );
          expect(liquidity).to.eq(parseUnits("0"));
          expect(shortfall).to.eq(parseUnits("0"));
        });
        it("AND she has 799+interest debt and is owed 1000DAI", async () => {
          const [supplied, borrowed] = await fixedLenderDAI.getAccountSnapshot(
            laura.address,
            nextPoolID
          );

          expect(supplied).to.be.eq(parseUnits("1000"));
          expect(borrowed).to.eq(parseUnits("800"));
        });
      });
    });
  });

  describe("unpaid debts after maturity", () => {
    describe("GIVEN a well funded maturity pool (10kdai, laura), AND collateral for the borrower, (10kusdc, bob)", () => {
      beforeEach(async () => {
        await exactlyEnv.depositMP("DAI", nextPoolID, "10000");
        exactlyEnv.switchWallet(bob);
        await exactlyEnv.depositSP("USDC", "10000");
      });
      describe("WHEN bob asks for a 7kdai loan (10kusdc should give him 8kusd liquidity)", () => {
        beforeEach(async () => {
          await exactlyEnv.borrowMP("DAI", nextPoolID, "7000");
        });
        it("THEN bob has 1kusd liquidity and no shortfall", async () => {
          const [liquidity, shortfall] = await auditor.getAccountLiquidity(
            bob.address
          );
          expect(liquidity).to.be.eq(parseUnits("1000"));
          expect(shortfall).to.eq(parseUnits("0"));
        });
        describe("AND WHEN moving to five days after the maturity date", () => {
          beforeEach(async () => {
            // Move in time to maturity
            await exactlyEnv.moveInTime(nextPoolID + 5 * new ExaTime().ONE_DAY);
          });
          it("THEN 5 days of *daily* base rate interest is charged, adding 0.02*5 =10% interest to the debt", async () => {
            const [liquidity, shortfall] = await auditor.getAccountLiquidity(
              bob.address
            );
            // Based on the events emitted, we calculate the liquidity
            // This is because we need to take into account the fixed rates
            // that the borrow and the lent got at the time of the transaction
            const totalSupplyAmount = parseUnits("10000");
            const totalBorrowAmount = parseUnits("7000");
            const calculatedLiquidity = totalSupplyAmount.sub(
              totalBorrowAmount.mul(2).mul(5).div(100) // 2% * 5 days
            );
            // TODO: this should equal
            expect(liquidity).to.be.lt(calculatedLiquidity);
            expect(shortfall).to.eq(parseUnits("0"));
          });
          describe("AND WHEN moving to fifteen days after the maturity date", () => {
            beforeEach(async () => {
              // Move in time to maturity
              await exactlyEnv.moveInTime(
                nextPoolID + 15 * new ExaTime().ONE_DAY
              );
            });
            it("THEN 15 days of *daily* base rate interest is charged, adding 0.02*15 =35% interest to the debt, causing a shortfall", async () => {
              const [liquidity, shortfall] = await auditor.getAccountLiquidity(
                bob.address
              );
              // Based on the events emitted, we calculate the liquidity
              // This is because we need to take into account the fixed rates
              // that the borrow and the lent got at the time of the transaction
              const totalSupplyAmount = parseUnits("10000");
              const totalBorrowAmount = parseUnits("7000");
              const calculatedShortfall = totalSupplyAmount.sub(
                totalBorrowAmount.mul(2).mul(15).div(100) // 2% * 15 days
              );
              expect(shortfall).to.be.lt(calculatedShortfall);
              expect(liquidity).to.eq(parseUnits("0"));
            });
          });
        });
      });
    });
  });

  describe("support for tokens with different decimals", () => {
    describe("GIVEN liquidity on the USDC pool ", () => {
      beforeEach(async () => {
        const amount = parseUnits("3", 6);
        await usdc.connect(laura).approve(fixedLenderUSDC.address, amount);
        await fixedLenderUSDC
          .connect(laura)
          .depositToMaturityPool(amount, nextPoolID, amount);
      });
      describe("WHEN bob does a 1 sat deposit", () => {
        beforeEach(async () => {
          await wbtc.connect(bob).approve(fixedLenderWBTC.address, "10000000");
          await fixedLenderWBTC.depositToMaturityPool("1", nextPoolID, "1");
        });
        it("THEN bobs liquidity is 63000 * 0.6 * 10 ^ - 8 usd == 3.78*10^14 minimal usd units", async () => {
          const [liquidity] = await auditor.getAccountLiquidity(
            bob.address,
            nextPoolID
          );
          expect(liquidity).to.eq(parseUnits("3.78", 14));
        });
        it("AND WHEN he tries to take a 4*10^14 usd USDC loan, THEN it reverts", async () => {
          // We expect liquidity to be equal to zero
          await expect(
            fixedLenderUSDC
              .connect(bob)
              .borrowFromMaturityPool("400", nextPoolID, "400")
          ).to.be.revertedWith(
            errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY)
          );
        });
        describe("AND WHEN he takes a 3*10^14 USDC loan", () => {
          beforeEach(async () => {
            await fixedLenderUSDC
              .connect(bob)
              .borrowFromMaturityPool("300", nextPoolID, "300");
          });
          it("THEN he has 7.8*10^13 usd left of liquidity", async () => {
            const [liquidity] = await auditor.getAccountLiquidity(
              bob.address,
              nextPoolID
            );
            expect(liquidity).to.eq(parseUnits("7.8", 13));
          });
        });
      });
    });
    describe("GIVEN theres liquidity on the btc fixedLender", () => {
      beforeEach(async () => {
        // laura supplies wbtc to the protocol to have lendable money in the pool
        exactlyEnv.switchWallet(laura);
        await exactlyEnv.depositMP("WBTC", nextPoolID, "3");
      });

      describe("AND GIVEN Bob provides 60kdai (18 decimals) as collateral", () => {
        beforeEach(async () => {
          exactlyEnv.switchWallet(bob);
          await exactlyEnv.depositSP("DAI", "60000");
        });
        // Here I'm trying to make sure we use the borrowed token's decimals
        // properly to compute liquidity
        // if we asume (wrongly) that all tokens have 18 decimals, then computing
        // the simulated liquidity for a token  with less than 18 decimals will
        // enable the creation of an undercolalteralized loan, since the
        // simulated liquidity would be orders of magnitude lower than the real
        // one
        it("WHEN he tries to take a 1btc (8 decimals) loan (100% collateralization), THEN it reverts", async () => {
          // We expect liquidity to be equal to zero
          await expect(
            exactlyEnv.borrowMP("WBTC", nextPoolID, "1")
          ).to.be.revertedWith(
            errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY)
          );
        });
      });

      describe("AND GIVEN Bob provides 20kdai (18 decimals) and 40kusdc (6 decimals) as collateral", () => {
        beforeEach(async () => {
          exactlyEnv.switchWallet(bob);
          await exactlyEnv.depositSP("DAI", "20000");
          await exactlyEnv.depositSP("USDC", "40000");
        });
        describe("AND GIVEN Bob takes a 0.5wbtc loan (200% collateralization)", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("WBTC", nextPoolID, "0.5");
          });
          // this is similar to the previous test case, but instead of
          // computing the simulated liquidity with a supplyAmount of zero and
          // the to-be-loaned amount as the borrowAmount, the amount of
          // collateral to withdraw is passed as the supplyAmount
          it("WHEN he tries to withdraw the usdc (8 decimals) collateral, THEN it reverts ()", async () => {
            // We expect liquidity to be equal to zero
            await expect(
              exactlyEnv.withdrawSP("USDC", "40000")
            ).to.be.revertedWith(
              errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY)
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
