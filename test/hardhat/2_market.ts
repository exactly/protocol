import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { Auditor, Market, MockERC20, MockInterestRateModel, WETH } from "../../types";
import decodeMaturities from "./utils/decodeMaturities";
import timelockExecute from "./utils/timelockExecute";
import futurePools from "./utils/futurePools";

const { parseUnits, getUnnamedSigners, getNamedSigner, getContract, provider } = ethers;
const { deploy, fixture } = deployments;

describe("Market", function () {
  let dai: MockERC20;
  let weth: WETH;
  let auditor: Auditor;
  let marketDAI: Market;
  let marketWETH: Market;
  let irm: MockInterestRateModel;

  let maria: SignerWithAddress;
  let john: SignerWithAddress;
  let owner: SignerWithAddress;
  let penaltyRate: bigint;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [maria, john] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await fixture("Markets");

    dai = await getContract<MockERC20>("DAI", maria);
    weth = await getContract<WETH>("WETH", maria);
    auditor = await getContract<Auditor>("Auditor", maria);
    marketDAI = await getContract<Market>("MarketDAI", maria);
    marketWETH = await getContract<Market>("MarketWETH", maria);
    penaltyRate = await marketDAI.penaltyRate();

    await deploy("MockInterestRateModel", { args: [0], from: owner.address });
    irm = await getContract<MockInterestRateModel>("MockInterestRateModel", maria);

    await timelockExecute(owner, marketDAI, "setBackupFeeRate", [0]);
    await timelockExecute(owner, marketWETH, "setBackupFeeRate", [0]);
    await timelockExecute(owner, marketDAI, "setInterestRateModel", [irm.target]);
    await timelockExecute(owner, marketDAI, "setReserveFactor", [0]);
    for (const signer of [maria, john]) {
      await dai.connect(owner).mint(signer.address, parseUnits("10000"));
      await dai.connect(signer).approve(marketDAI.target, parseUnits("10000"));
      await weth.deposit({ value: parseUnits("10") });
      await weth.approve(marketWETH.target, parseUnits("10"));
    }
    await provider.send("evm_increaseTime", [9_011]);
  });

  describe("small positions", () => {
    describe("WHEN depositing 3wei of a dai", () => {
      beforeEach(async () => {
        await marketDAI.deposit(3, maria.address);
        // add liquidity to the maturity
        await marketDAI.depositAtMaturity(futurePools(1)[0], 3, 0, maria.address);
        await provider.send("evm_increaseTime", [9_011]);
      });

      it("THEN the Market registers a supply of 3 wei DAI for the account (exposed via accountSnapshot)", async () => {
        expect(await marketDAI.maxWithdraw(maria.address)).to.equal(3);
      });

      it("AND the Market Size of the smart pool is 3 wei of a dai", async () => {
        expect(await marketDAI.totalAssets()).to.equal(3);
      });

      it("AND its not possible to borrow 3 wei of a dai", async () => {
        await expect(
          marketDAI.borrowAtMaturity(futurePools(1)[0], 3, 6, maria.address, maria.address),
        ).to.be.revertedWithCustomError(auditor, "InsufficientAccountLiquidity");
      });

      describe("AND WHEN borrowing 1 wei of DAI", () => {
        beforeEach(async () => {
          await expect(await marketDAI.borrowAtMaturity(futurePools(1)[0], 1, 1, maria.address, maria.address))
            .to.emit(marketDAI, "BorrowAtMaturity")
            .withArgs(futurePools(1)[0], maria.address, maria.address, maria.address, 1, 0);
        });

        it("AND the Market Size of the smart pool remains in 3 wei of a dai", async () => {
          expect(await marketDAI.totalAssets()).to.be.equal(3);
        });

        it("AND a 1 wei of DAI borrow is registered", async () => {
          expect((await marketDAI.fixedPools(futurePools(1)[0]))[0]).to.equal(1);
        });
      });
    });
  });

  describe("WHEN depositing 100 DAI to a maturity pool", () => {
    beforeEach(async () => {
      await expect(marketDAI.depositAtMaturity(futurePools(1)[0], parseUnits("100"), parseUnits("100"), maria.address))
        .to.emit(marketDAI, "DepositAtMaturity")
        .withArgs(futurePools(1)[0], maria.address, maria.address, parseUnits("100"), 0);
    });

    it("AND the Market contract has a balance of 100 DAI", async () => {
      expect(await dai.balanceOf(marketDAI.target)).to.equal(parseUnits("100"));
    });

    it("AND the Market registers a supply of 100 DAI for the account", async () => {
      expect((await marketDAI.fixedDepositPositions(futurePools(1)[0], maria.address))[0]).to.equal(parseUnits("100"));
    });

    it("WHEN trying to borrow DAI THEN it reverts with INSUFFICIENT_LIQUIDITY since collateral was not deposited yet", async () => {
      await expect(
        marketDAI.borrowAtMaturity(futurePools(1)[0], 1000, 2000, maria.address, maria.address),
      ).to.be.revertedWithCustomError(auditor, "InsufficientAccountLiquidity");
    });

    describe("AND WHEN depositing 50 DAI to the same maturity, as the same account", () => {
      beforeEach(async () => {
        await expect(marketDAI.depositAtMaturity(futurePools(1)[0], parseUnits("50"), parseUnits("50"), maria.address))
          .to.emit(marketDAI, "DepositAtMaturity")
          .withArgs(futurePools(1)[0], maria.address, maria.address, parseUnits("50"), 0);
      });

      it("AND the Market contract has a balance of 150 DAI", async () => {
        expect(await dai.balanceOf(marketDAI.target)).to.equal(parseUnits("150"));
      });

      it("AND the Market does not register a smart pool balance deposit (exposed via accountSnapshot)", async () => {
        expect(await marketDAI.maxWithdraw(maria.address)).to.equal(0);
      });
    });

    describe("WHEN depositing collateral and borrowing 60 DAI from the same maturity", () => {
      let timestamp: number;

      beforeEach(async () => {
        await marketDAI.deposit(parseUnits("100"), maria.address);
        const tx = await marketDAI.borrowAtMaturity(
          futurePools(1)[0],
          parseUnits("60"),
          parseUnits("66"),
          maria.address,
          maria.address,
        );
        await expect(tx)
          .to.emit(marketDAI, "BorrowAtMaturity")
          .withArgs(futurePools(1)[0], maria.address, maria.address, maria.address, parseUnits("60"), 0);
        const { blockNumber } = (await tx.wait())!;
        timestamp = (await provider.getBlock(blockNumber))!.timestamp;
      });

      it("AND a 60 DAI borrow is registered", async () => {
        expect((await marketDAI.fixedPools(futurePools(1)[0]))[0]).to.equal(parseUnits("60"));
      });

      it("AND contract's state variable fixedBorrows registers the maturity where the account borrowed from", async () => {
        const { fixedBorrows } = await marketDAI.accounts(maria.address);
        expect(decodeMaturities(fixedBorrows)).contains(futurePools(1)[0]);
      });

      describe("AND WHEN trying to repay 100 (too much)", () => {
        let balanceBefore: bigint;

        beforeEach(async () => {
          balanceBefore = await dai.balanceOf(maria.address);
          await marketDAI.repayAtMaturity(futurePools(1)[0], parseUnits("100"), parseUnits("100"), maria.address);
        });

        it("THEN all debt is repaid", async () => {
          expect(await marketDAI.previewDebt(maria.address)).to.equal(0);
        });

        it("THEN the 40 spare amount is not discounted from the account balance", async () => {
          expect(await dai.balanceOf(maria.address)).to.equal(balanceBefore - parseUnits("60"));
        });
      });

      describe("AND WHEN borrowing 60 DAI from another maturity AND repaying only first debt", () => {
        beforeEach(async () => {
          await marketDAI.deposit(parseUnits("1000"), maria.address);
          await provider.send("evm_setNextBlockTimestamp", [timestamp + 218]);
          await marketDAI.borrowAtMaturity(
            futurePools(2)[1],
            parseUnits("60"),
            parseUnits("60"),
            maria.address,
            maria.address,
          );
          await marketDAI.repayAtMaturity(futurePools(1)[0], parseUnits("60"), parseUnits("60"), maria.address);
        });

        it("THEN contract's state variable fixedBorrows registers the second maturity where the account borrowed from", async () => {
          const { fixedBorrows } = await marketDAI.accounts(maria.address);
          expect(decodeMaturities(fixedBorrows)).contains(futurePools(2)[1]);
        });
      });

      describe("AND WHEN fully repaying the debt", () => {
        beforeEach(async () => {
          await expect(
            await marketDAI.repayAtMaturity(futurePools(1)[0], parseUnits("60"), parseUnits("60"), maria.address),
          )
            .to.emit(marketDAI, "RepayAtMaturity")
            .withArgs(futurePools(1)[0], maria.address, maria.address, parseUnits("60"), parseUnits("60"));
        });

        it("AND contract's state variable fixedBorrows does not register the maturity where the account borrowed from anymore", async () => {
          const { fixedBorrows } = await marketDAI.accounts(maria.address);
          expect(decodeMaturities(fixedBorrows).length).eq(0);
        });

        describe("AND WHEN withdrawing collateral and maturity pool deposit", () => {
          beforeEach(async () => {
            await marketDAI.withdraw(parseUnits("100"), maria.address, maria.address);
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0] + 1]);
            await marketDAI.withdrawAtMaturity(
              futurePools(1)[0],
              parseUnits("100"),
              parseUnits("100"),
              maria.address,
              maria.address,
            );
          });

          it("THEN the collateral & deposits are returned to Maria (10000)", async () => {
            expect(await dai.balanceOf(maria.address)).to.equal(parseUnits("10000"));
            expect(await dai.balanceOf(marketDAI.target)).to.equal(0);
          });

          it("AND contract's state variable fixedDeposits does not register the maturity where the account deposited to anymore", async () => {
            const { fixedDeposits } = await marketDAI.accounts(maria.address);
            expect(decodeMaturities(fixedDeposits).length).eq(0);
          });
        });

        describe("AND WHEN withdrawing MORE from maturity pool than maria has", () => {
          beforeEach(async () => {
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0] + 1]);
            await marketDAI.withdrawAtMaturity(
              futurePools(1)[0],
              parseUnits("1000000"),
              parseUnits("100"),
              maria.address,
              maria.address,
            );
          });

          it("THEN the total amount withdrawn is 9900 (the max)", async () => {
            expect(await dai.balanceOf(maria.address)).to.equal(parseUnits("9900"));
          });

          it("AND contract's state variable fixedDeposits does not register the maturity where the account deposited to anymore", async () => {
            const { fixedDeposits } = await marketDAI.accounts(maria.address);
            expect(decodeMaturities(fixedDeposits).length).eq(0);
          });
        });

        describe("AND WHEN withdrawing LESS from maturity pool than maria has", () => {
          beforeEach(async () => {
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0] + 1]);
            await marketDAI.withdrawAtMaturity(
              futurePools(1)[0],
              parseUnits("50"),
              parseUnits("50"),
              maria.address,
              maria.address,
            );
          });

          it("THEN the total amount withdrawn is 9950 (leaving 150 in Market / 100 in SP / 50 in MP)", async () => {
            expect(await dai.balanceOf(maria.address)).to.equal(parseUnits("9850"));
            expect(await dai.balanceOf(marketDAI.target)).to.equal(parseUnits("150"));
          });
        });
      });

      describe("GIVEN the maturity pool matures", () => {
        beforeEach(async () => {
          await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0] + 1]);
        });

        it("WHEN trying to withdraw an amount of zero THEN it reverts", async () => {
          await expect(
            marketDAI.withdrawAtMaturity(futurePools(1)[0], 0, 0, maria.address, maria.address),
          ).to.be.revertedWithCustomError(marketDAI, "ZeroWithdraw");
        });
      });

      describe("AND WHEN partially (40DAI, 66%) repaying the debt", () => {
        beforeEach(async () => {
          await expect(marketDAI.repayAtMaturity(futurePools(1)[0], parseUnits("40"), parseUnits("40"), maria.address))
            .to.emit(marketDAI, "RepayAtMaturity")
            .withArgs(futurePools(1)[0], maria.address, maria.address, parseUnits("40"), parseUnits("40"));
        });

        it("AND Maria still owes 20 DAI", async () => {
          expect(await marketDAI.previewDebt(maria.address)).to.equal(parseUnits("20"));
        });

        describe("AND WHEN moving in time to 1 day after maturity", () => {
          let penalty: bigint;

          beforeEach(async () => {
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0] + 86_400]);
            penalty = ((parseUnits("20") * penaltyRate) / parseUnits("1")) * 86_400n;
            expect(penalty).to.be.gt(0);
          });

          it("THEN Maria owes (accountSnapshot) 20 DAI of principal + (20*0.02 ~= 0.0400032 ) DAI of late payment penalties", async () => {
            await provider.send("evm_mine", []);
            expect(await marketDAI.previewDebt(maria.address)).to.equal(parseUnits("20") + penalty);
          });

          describe("AND WHEN repaying the rest of the 20.4 owed DAI", () => {
            beforeEach(async () => {
              const amount = parseUnits("20") + penalty;
              await marketDAI.repayAtMaturity(futurePools(1)[0], amount, amount, maria.address);
            });

            it("THEN all debt is repaid", async () => {
              expect(await marketDAI.previewDebt(maria.address)).to.equal(0);
            });
          });

          describe("AND WHEN repaying more than what is owed (30 DAI)", () => {
            beforeEach(async () => {
              await marketDAI.repayAtMaturity(futurePools(1)[0], parseUnits("30"), parseUnits("30"), maria.address);
            });

            it("THEN all debt is repaid", async () => {
              expect(await marketDAI.previewDebt(maria.address)).to.equal(0);
            });
          });
        });
      });
    });

    describe("AND WHEN moving in time to maturity AND withdrawing from the maturity pool", () => {
      beforeEach(async () => {
        await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0] + 1]);
        await expect(
          marketDAI.withdrawAtMaturity(
            futurePools(1)[0],
            parseUnits("100"),
            parseUnits("100"),
            maria.address,
            maria.address,
          ),
        )
          .to.emit(marketDAI, "WithdrawAtMaturity")
          .withArgs(
            futurePools(1)[0],
            maria.address,
            maria.address,
            maria.address,
            parseUnits("100"),
            parseUnits("100"),
          );
      });

      it("THEN 100 DAI are returned to Maria", async () => {
        expect(await dai.balanceOf(maria.address)).to.equal(parseUnits("10000"));
        expect(await dai.balanceOf(marketDAI.target)).to.equal(0);
      });
    });
  });

  describe("maturity clearing:", () => {
    describe("GIVEN maria borrows from the first, third and fifth maturity", () => {
      beforeEach(async () => {
        await timelockExecute(owner, marketDAI, "setMaxFuturePools", [5]);
        await marketDAI.connect(maria).deposit(parseUnits("100"), maria.address);
        await provider.send("evm_increaseTime", [9011]);

        await marketDAI
          .connect(maria)
          .borrowAtMaturity(futurePools(1)[0], parseUnits("1"), parseUnits("1"), maria.address, maria.address);
        await marketDAI
          .connect(maria)
          .borrowAtMaturity(futurePools(3)[2], parseUnits("1"), parseUnits("1"), maria.address, maria.address);
        await marketDAI
          .connect(maria)
          .borrowAtMaturity(futurePools(5)[4], parseUnits("1"), parseUnits("1"), maria.address, maria.address);
      });

      describe("WHEN she repays the first maturity borrow", () => {
        beforeEach(async () => {
          await marketDAI
            .connect(maria)
            .repayAtMaturity(futurePools(1)[0], parseUnits("1"), parseUnits("1"), maria.address);
        });

        it("THEN her debt is equal to both borrows left", async () => {
          expect(await marketDAI.previewDebt(maria.address)).to.be.eq(parseUnits("2"));
        });

        describe("AND WHEN she repays the third maturity borrow", () => {
          beforeEach(async () => {
            await marketDAI
              .connect(maria)
              .repayAtMaturity(futurePools(3)[2], parseUnits("1"), parseUnits("1"), maria.address);
          });

          it("THEN her debt is equal to one borrow left", async () => {
            expect(await marketDAI.previewDebt(maria.address)).to.be.eq(parseUnits("1"));
          });

          describe("AND WHEN she repays the fifth maturity borrow", () => {
            beforeEach(async () => {
              await marketDAI
                .connect(maria)
                .repayAtMaturity(futurePools(5)[4], parseUnits("1"), parseUnits("1"), maria.address);
            });

            it("THEN her debt is equal to one borrow left", async () => {
              expect(await marketDAI.previewDebt(maria.address)).to.be.eq(0);
            });
          });
        });
      });
    });
  });

  describe("simple validations:", () => {
    it("WHEN calling setMaxFuturePools from a regular (non-admin) account, THEN it reverts with an AccessControl error", async () => {
      await expect(marketDAI.setMaxFuturePools(12)).to.be.revertedWithoutReason();
    });

    it("WHEN calling setMaxFuturePools, THEN the maxFuturePools should be updated", async () => {
      await timelockExecute(owner, marketDAI, "setMaxFuturePools", [15]);
      expect(await marketDAI.maxFuturePools()).to.be.equal(15);
    });

    it("WHEN calling setEarningsAccumulatorSmoothFactor from a regular (non-admin) account, THEN it reverts with an AccessControl error", async () => {
      await expect(marketDAI.setEarningsAccumulatorSmoothFactor(parseUnits("2"))).to.be.revertedWithoutReason();
    });

    it("WHEN calling setEarningsAccumulatorSmoothFactor, THEN the earningsAccumulatorSmoothFactor should be updated", async () => {
      await timelockExecute(owner, marketDAI, "setEarningsAccumulatorSmoothFactor", [parseUnits("2")]);
      expect(await marketDAI.earningsAccumulatorSmoothFactor()).to.be.equal(parseUnits("2"));
    });

    it("WHEN calling setTreasury from a regular (non-admin) account, THEN it reverts with an AccessControl error", async () => {
      await expect(marketDAI.setTreasury(maria.address, 0)).to.be.revertedWithoutReason();
    });

    it("WHEN calling setTreasury, THEN the treasury address and treasury fee should be updated", async () => {
      await timelockExecute(owner, marketDAI, "setTreasury", [maria.address, parseUnits("0.1")]);
      expect(await marketDAI.treasury()).to.be.equal(maria.address);
      expect(await marketDAI.treasuryFeeRate()).to.be.equal(parseUnits("0.1"));
    });
  });

  describe("GIVEN an interest rate of 2%", () => {
    beforeEach(async () => {
      const { address } = await deploy("MockInterestRateModel", { args: [parseUnits("0.02")], from: maria.address });
      await timelockExecute(owner, marketDAI, "setInterestRateModel", [address]);
      await marketDAI.deposit(parseUnits("1"), maria.address);
      await provider.send("evm_increaseTime", [9_011]);
      await auditor.enterMarket(marketDAI.target);
      // add liquidity to the maturity
      await marketDAI.depositAtMaturity(futurePools(1)[0], parseUnits("1"), parseUnits("1"), maria.address);
    });

    it("WHEN trying to borrow 0.8 DAI with a max amount of debt of 0.8 DAI, THEN it reverts with TOO_MUCH_SLIPPAGE", async () => {
      await expect(
        marketDAI.borrowAtMaturity(
          futurePools(1)[0],
          parseUnits("0.8"),
          parseUnits("0.8"),
          maria.address,
          maria.address,
        ),
      ).to.be.revertedWithCustomError(marketDAI, "Disagreement");
    });

    it("AND contract's state variable fixedDeposits registers the maturity where the account supplied to", async () => {
      const { fixedDeposits } = await marketDAI.accounts(maria.address);
      expect(decodeMaturities(fixedDeposits)).contains(futurePools(1)[0]);
    });

    it("WHEN trying to deposit 100 DAI with a minimum required amount to be received of 103, THEN 102 are received instead AND the transaction reverts with TOO_MUCH_SLIPPAGE", async () => {
      await expect(
        marketDAI.depositAtMaturity(futurePools(1)[0], parseUnits("100"), parseUnits("103"), maria.address),
      ).to.be.revertedWithCustomError(marketDAI, "Disagreement");
    });
  });

  describe("GIVEN John deposited 12 DAI to the smart pool AND Maria borrowed 6 DAI from an empty maturity", () => {
    beforeEach(async () => {
      await marketWETH.deposit(parseUnits("10"), maria.address);
      await auditor.enterMarket(marketWETH.target);

      await marketDAI.connect(john).deposit(parseUnits("12"), john.address);
      await provider.send("evm_increaseTime", [9_011]);

      await marketDAI.borrowAtMaturity(
        futurePools(2)[1],
        parseUnits("6"),
        parseUnits("6"),
        maria.address,
        maria.address,
      );
    });

    it("WHEN Maria tries to borrow 5.99 more DAI on the same maturity, THEN it does not revert", async () => {
      await expect(
        marketDAI.borrowAtMaturity(
          futurePools(2)[1],
          parseUnits("5.99"),
          parseUnits("5.99"),
          maria.address,
          maria.address,
        ),
      ).to.not.be.reverted;
    });

    it("WHEN Maria tries to borrow 5.99 more DAI from the smart pool, THEN it does not revert", async () => {
      await expect(marketDAI.borrow(parseUnits("5.99"), maria.address, maria.address)).to.not.be.reverted;
    });

    it("WHEN Maria tries to borrow 6 more DAI on the same maturity (remaining liquidity), THEN it does not revert", async () => {
      await expect(
        marketDAI.borrowAtMaturity(futurePools(2)[1], parseUnits("6"), parseUnits("6"), maria.address, maria.address),
      ).to.not.be.reverted;
    });

    it("WHEN Maria tries to borrow 6 more DAI from the smart pool, THEN it does not revert", async () => {
      await expect(marketDAI.borrow(parseUnits("6"), maria.address, maria.address)).to.not.be.reverted;
    });

    it("WHEN Maria tries to borrow 6.01 more DAI on another maturity, THEN it fails with InsufficientProtocolLiquidity", async () => {
      await expect(
        marketDAI.borrowAtMaturity(
          futurePools(2)[1],
          parseUnits("6.01"),
          parseUnits("7"),
          maria.address,
          maria.address,
        ),
      ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
    });

    it("WHEN Maria tries to borrow 6.01 more DAI from the smart pool, THEN it fails with InsufficientProtocolLiquidity", async () => {
      await expect(marketDAI.borrow(parseUnits("6.01"), maria.address, maria.address)).to.be.revertedWithCustomError(
        marketDAI,
        "InsufficientProtocolLiquidity",
      );
    });

    it("WHEN Maria tries to borrow 12 more DAI on the same maturity, THEN it fails with InsufficientProtocolLiquidity", async () => {
      await expect(
        marketDAI.borrowAtMaturity(futurePools(2)[1], parseUnits("12"), parseUnits("12"), maria.address, maria.address),
      ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
    });

    it("WHEN Maria tries to borrow 12 more DAI from the smart pool, THEN it fails with InsufficientProtocolLiquidity", async () => {
      await expect(marketDAI.borrow(parseUnits("12"), maria.address, maria.address)).to.be.revertedWithCustomError(
        marketDAI,
        "InsufficientProtocolLiquidity",
      );
    });

    it("WHEN John tries to withdraw 6 DAI from the smart pool, THEN it does not revert", async () => {
      await expect(marketDAI.connect(john).withdraw(parseUnits("6"), john.address, john.address)).to.not.be.reverted;
    });

    it("WHEN John tries to withdraw his 12 DAI from the smart pool, THEN it fails with InsufficientProtocolLiquidity", async () => {
      await expect(
        marketDAI.connect(john).withdraw(parseUnits("12"), john.address, john.address),
      ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
    });

    describe("AND GIVEN maria borrows 3 from the smart pool", () => {
      let timestamp: number;

      beforeEach(async () => {
        const { blockNumber } = (await (await marketDAI.borrow(parseUnits("3"), maria.address, maria.address)).wait())!;
        timestamp = (await provider.getBlock(blockNumber))!.timestamp;
      });

      it("WHEN John tries to withdraw 6 DAI from the smart pool, THEN it fails with InsufficientProtocolLiquidity", async () => {
        await expect(
          marketDAI.connect(john).withdraw(parseUnits("6"), john.address, john.address),
        ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
      });

      it("WHEN John tries to withdraw 3 DAI from the smart pool, THEN it does not revert", async () => {
        await expect(marketDAI.connect(john).withdraw(parseUnits("3"), john.address, john.address)).to.not.be.reverted;
      });

      it("WHEN Maria tries to borrow 3 more DAI from the smart pool, THEN it does not revert", async () => {
        await expect(marketDAI.borrow(parseUnits("3"), maria.address, maria.address)).to.not.be.reverted;
      });

      it("WHEN Maria tries to borrow 3.01 DAI from the smart pool, THEN it fails with InsufficientProtocolLiquidity", async () => {
        await expect(marketDAI.borrow(parseUnits("3.01"), maria.address, maria.address)).to.be.revertedWithCustomError(
          marketDAI,
          "InsufficientProtocolLiquidity",
        );
      });

      describe("AND WHEN 5 years go by and a lot of flexible borrows are added", () => {
        beforeEach(async () => {
          await provider.send("evm_setNextBlockTimestamp", [timestamp + 86_400 * 365 * 5]);

          // borrow and repay to have all those flexible fees accrued
          await marketDAI.borrow("1", maria.address, maria.address);
          await marketDAI.refund("1", maria.address);
        });

        it("WHEN Maria tries to borrow 3 more DAI from the smart pool, THEN it does not revert", async () => {
          // despite a lot of fees being added to the floatingDebt all those same fees are also added
          // to the floatingAssets at the same time
          await expect(marketDAI.borrow(parseUnits("3"), maria.address, maria.address)).to.not.be.reverted;
        });

        it("WHEN Maria tries to borrow 3.01 DAI from the smart pool, THEN it fails with InsufficientProtocolLiquidity", async () => {
          await expect(
            marketDAI.borrow(parseUnits("3.01"), maria.address, maria.address),
          ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
        });
      });
    });

    describe("AND John deposited 2388 DAI to the smart pool", () => {
      beforeEach(async () => {
        await marketDAI.connect(john).deposit(parseUnits("2388"), maria.address);
        await provider.send("evm_increaseTime", [9011]);
      });

      it("WHEN Maria tries to borrow 2500 DAI from a maturity, THEN it fails with InsufficientProtocolLiquidity", async () => {
        await expect(
          marketDAI.borrowAtMaturity(
            futurePools(2)[1],
            parseUnits("2500"),
            parseUnits("5000"),
            maria.address,
            maria.address,
          ),
        ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
      });

      it("WHEN Maria tries to borrow 2500 DAI from the smart pool, THEN it fails with InsufficientProtocolLiquidity", async () => {
        await expect(marketDAI.borrow(parseUnits("2500"), maria.address, maria.address)).to.be.revertedWithCustomError(
          marketDAI,
          "InsufficientProtocolLiquidity",
        );
      });

      it("WHEN Maria tries to borrow 150 DAI from a maturity, THEN it succeeds", async () => {
        await expect(
          marketDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("150"),
            parseUnits("150"),
            maria.address,
            maria.address,
          ),
        ).to.not.be.reverted;
      });

      it("WHEN Maria tries to borrow 150 DAI from the smart pool, THEN it succeeds", async () => {
        await expect(marketDAI.borrow(parseUnits("150"), maria.address, maria.address)).to.not.be.reverted;
      });
    });

    describe("AND John deposited 100 DAI to maturity", () => {
      beforeEach(async () => {
        await marketDAI
          .connect(john)
          .depositAtMaturity(futurePools(1)[0], parseUnits("100"), parseUnits("100"), john.address);
      });

      it("WHEN Maria tries to borrow 150 DAI, THEN it fails with InsufficientProtocolLiquidity", async () => {
        await expect(
          marketDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("150"),
            parseUnits("150"),
            maria.address,
            maria.address,
          ),
        ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
      });

      describe("AND John deposited 1200 DAI to the smart pool", () => {
        beforeEach(async () => {
          await marketDAI
            .connect(john)
            .depositAtMaturity(futurePools(1)[0], parseUnits("1200"), parseUnits("1200"), john.address);
        });

        it("WHEN Maria tries to borrow 1350 DAI, THEN it fails with InsufficientProtocolLiquidity", async () => {
          await expect(
            marketDAI.borrowAtMaturity(
              futurePools(1)[0],
              parseUnits("1350"),
              parseUnits("2000"),
              maria.address,
              maria.address,
            ),
          ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
        });

        it("WHEN Maria tries to borrow 200 DAI, THEN it succeeds", async () => {
          await expect(
            marketDAI.borrowAtMaturity(
              futurePools(1)[0],
              parseUnits("200"),
              parseUnits("200"),
              maria.address,
              maria.address,
            ),
          ).to.not.be.reverted;
        });

        it("WHEN Maria tries to borrow 150 DAI, THEN it succeeds", async () => {
          await expect(
            marketDAI.borrowAtMaturity(
              futurePools(1)[0],
              parseUnits("150"),
              parseUnits("150"),
              maria.address,
              maria.address,
            ),
          ).to.not.be.reverted;
        });
      });
    });
  });

  describe("GIVEN maria has plenty of WETH collateral", () => {
    beforeEach(async () => {
      await marketWETH.deposit(parseUnits("10"), maria.address);
      await auditor.enterMarket(marketDAI.target);
      await auditor.enterMarket(marketWETH.target);
    });

    describe("AND GIVEN she deposits 1000DAI into the next two maturity pools AND other 500 into the smart pool", () => {
      beforeEach(async () => {
        for (const pool of futurePools(2)) {
          await marketDAI.depositAtMaturity(pool, parseUnits("1000"), parseUnits("1000"), maria.address);
        }
        await marketDAI.deposit(parseUnits("6000"), maria.address);
        await provider.send("evm_increaseTime", [9011]);
      });

      describe("WHEN borrowing 1200 in the current maturity", () => {
        beforeEach(async () => {
          await marketDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("1200"),
            parseUnits("1200"),
            maria.address,
            maria.address,
          );
        });

        it("THEN all of the maturity pools funds are in use", async () => {
          const [borrowed, supplied] = await marketDAI.fixedPools(futurePools(1)[0]);
          expect(borrowed).to.gt(supplied);
        });

        it("AND 200 are borrowed from the smart pool", async () => {
          expect(await marketDAI.floatingBackupBorrowed()).to.equal(parseUnits("200"));
        });

        it("AND WHEN trying to withdraw 300 ==(500 available, 200 borrowed to MP) from the smart pool, THEN it succeeds", async () => {
          await expect(marketDAI.withdraw(parseUnits("300"), maria.address, maria.address)).to.not.be.reverted;
        });

        it("AND WHEN trying to withdraw 5900 >(6000 total, 200 borrowed to MP) from the smart pool, THEN it reverts because 100 of those 5900 are still lent to the maturity pool", async () => {
          await expect(
            marketDAI.withdraw(parseUnits("5900"), maria.address, maria.address),
          ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
        });

        describe("AND borrowing 1100 in a later maturity ", () => {
          beforeEach(async () => {
            await marketDAI.borrowAtMaturity(
              futurePools(2)[1],
              parseUnits("1100"),
              parseUnits("1100"),
              maria.address,
              maria.address,
            );
          });

          it("THEN all of the maturity pools funds are in use", async () => {
            const [borrowed, supplied] = await marketDAI.fixedPools(futurePools(2)[1]);
            expect(borrowed).to.gt(supplied);
          });

          it("THEN the later maturity owes 100 to the smart pool", async () => {
            const mp = await marketDAI.fixedPools(futurePools(2)[1]);
            expect(mp.borrowed - mp.supplied).to.equal(parseUnits("100"));
          });

          it("THEN the smart pool has lent 300 (100 from the later maturity one, 200 from the first one)", async () => {
            expect(await marketDAI.floatingBackupBorrowed()).to.equal(parseUnits("300"));
          });

          describe("AND WHEN repaying 50 DAI in the later maturity", () => {
            beforeEach(async () => {
              await marketDAI.repayAtMaturity(futurePools(2)[1], parseUnits("50"), parseUnits("50"), maria.address);
            });

            it("THEN 1050 DAI are borrowed", async () => {
              expect((await marketDAI.fixedPools(futurePools(2)[1])).borrowed).to.equal(parseUnits("1050"));
            });

            it("THEN the maturity pool doesn't have funds available", async () => {
              const [borrowed, supplied] = await marketDAI.fixedPools(futurePools(2)[1]);
              expect(borrowed).to.gt(supplied);
            });

            it("THEN the maturity pool owes 50 to the smart pool", async () => {
              const mp = await marketDAI.fixedPools(futurePools(2)[1]);
              expect(mp.borrowed - mp.supplied).to.equal(parseUnits("50"));
            });

            it("THEN the smart pool was repaid 50 DAI (SPborrowed=250)", async () => {
              expect(await marketDAI.floatingBackupBorrowed()).to.equal(parseUnits("250"));
            });
          });

          describe("AND WHEN john deposits 800 to the later maturity", () => {
            beforeEach(async () => {
              await marketDAI
                .connect(john)
                .depositAtMaturity(futurePools(2)[1], parseUnits("800"), parseUnits("800"), john.address);
            });

            it("THEN 1100 DAI are still borrowed", async () => {
              expect((await marketDAI.fixedPools(futurePools(2)[1])).borrowed).to.equal(parseUnits("1100"));
            });

            it("THEN the later maturity has 700 DAI available for borrowing", async () => {
              const [borrowed, supplied] = await marketDAI.fixedPools(futurePools(2)[1]);
              expect(supplied - borrowed).to.equal(parseUnits("700"));
            });

            it("THEN the later maturity has no supply from the Smart Pool", async () => {
              const mp = await marketDAI.fixedPools(futurePools(2)[1]);
              expect(mp.supplied).to.gt(mp.borrowed);
            });

            it("THEN the smart pool was repaid, and is still owed 200 from the current one", async () => {
              expect(await marketDAI.floatingBackupBorrowed()).to.equal(parseUnits("200"));
            });
          });
        });

        describe("AND WHEN john deposits 100 to the same maturity", () => {
          beforeEach(async () => {
            await marketDAI
              .connect(john)
              .depositAtMaturity(futurePools(1)[0], parseUnits("100"), parseUnits("100"), john.address);
          });

          it("THEN 1200 DAI are still borrowed", async () => {
            expect((await marketDAI.fixedPools(futurePools(1)[0])).borrowed).to.equal(parseUnits("1200"));
          });

          it("THEN the maturity pool still doesn't have funds available", async () => {
            const [borrowed, supplied] = await marketDAI.fixedPools(futurePools(1)[0]);
            expect(borrowed).to.gt(supplied);
          });

          it("THEN the maturity pool still owes 100 to the smart pool", async () => {
            const mp = await marketDAI.fixedPools(futurePools(1)[0]);
            expect(mp.borrowed - mp.supplied).to.equal(parseUnits("100"));
          });

          it("THEN the smart pool was repaid the other 100 (is owed still 100)", async () => {
            expect(await marketDAI.floatingBackupBorrowed()).to.equal(parseUnits("100"));
          });
        });

        describe("AND WHEN john deposits 300 to the same maturity", () => {
          beforeEach(async () => {
            await marketDAI
              .connect(john)
              .depositAtMaturity(futurePools(1)[0], parseUnits("300"), parseUnits("300"), john.address);
          });

          it("THEN 1200 DAI are still borrowed", async () => {
            expect((await marketDAI.fixedPools(futurePools(1)[0])).borrowed).to.equal(parseUnits("1200"));
          });

          it("THEN the maturity pool has 100 DAI available", async () => {
            const [borrowed, supplied] = await marketDAI.fixedPools(futurePools(1)[0]);
            expect(supplied - borrowed).to.equal(parseUnits("100"));
          });

          it("THEN the maturity pool doesn't owe the Smart Pool", async () => {
            const mp = await marketDAI.fixedPools(futurePools(1)[0]);
            expect(mp.supplied).to.gt(mp.borrowed);
          });
        });

        describe("AND WHEN repaying 100 DAI", () => {
          beforeEach(async () => {
            await marketDAI.repayAtMaturity(futurePools(1)[0], parseUnits("100"), parseUnits("100"), maria.address);
          });

          it("THEN 1100 DAI are still borrowed", async () => {
            expect((await marketDAI.fixedPools(futurePools(1)[0])).borrowed).to.equal(parseUnits("1100"));
          });

          it("THEN the maturity pool doesn't have funds available", async () => {
            const [borrowed, supplied] = await marketDAI.fixedPools(futurePools(1)[0]);
            expect(borrowed).to.gt(supplied);
          });

          it("THEN the maturity pool still owes 100 to the smart pool (100 repaid)", async () => {
            const mp = await marketDAI.fixedPools(futurePools(1)[0]);
            expect(mp.borrowed - mp.supplied).to.equal(parseUnits("100"));
          });
        });

        describe("AND WHEN repaying 300 DAI", () => {
          beforeEach(async () => {
            await marketDAI.repayAtMaturity(futurePools(1)[0], parseUnits("300"), parseUnits("300"), maria.address);
          });

          it("THEN 900 DAI are still borrowed", async () => {
            expect((await marketDAI.fixedPools(futurePools(1)[0])).borrowed).to.equal(parseUnits("900"));
          });

          it("THEN the maturity pool has 100 DAI available", async () => {
            const [borrowed, supplied] = await marketDAI.fixedPools(futurePools(1)[0]);
            expect(supplied - borrowed).to.equal(parseUnits("100"));
          });

          it("THEN the maturity pool doesn't owe the Smart Pool", async () => {
            const mp = await marketDAI.fixedPools(futurePools(1)[0]);
            expect(mp.supplied).to.gt(mp.borrowed);
          });
        });

        describe("AND WHEN repaying in full (1200 DAI)", () => {
          beforeEach(async () => {
            await marketDAI.repayAtMaturity(futurePools(1)[0], parseUnits("1200"), parseUnits("1200"), maria.address);
          });

          it("THEN the maturity pool has 1000 DAI available", async () => {
            const [borrowed, supplied] = await marketDAI.fixedPools(futurePools(1)[0]);
            expect(supplied - borrowed).to.equal(parseUnits("1000"));
          });
        });
      });
    });

    describe("AND GIVEN she borrows 5k DAI", () => {
      beforeEach(async () => {
        // first fund the maturity pool so it has liquidity to borrow
        await marketDAI.depositAtMaturity(futurePools(1)[0], parseUnits("5000"), parseUnits("5000"), maria.address);
        await marketDAI.borrowAtMaturity(
          futurePools(1)[0],
          parseUnits("5000"),
          parseUnits("5000"),
          maria.address,
          maria.address,
        );
      });

      describe("AND WHEN moving in time to 20 days after maturity", () => {
        beforeEach(async () => {
          await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0] + 86_400 * 20]);
        });

        it("THEN Maria owes (accountSnapshot) 5k + approx 2.8k DAI in penalties", async () => {
          await provider.send("evm_mine", []);
          expect(await marketDAI.previewDebt(maria.address)).to.equal(
            parseUnits("5000") + ((parseUnits("5000") * penaltyRate) / parseUnits("1")) * 86_400n * 20n,
          );
        });
      });

      describe("AND WHEN moving in time to 20 days after maturity but repaying really small amounts within some days", () => {
        beforeEach(async () => {
          for (const days of [5, 10, 15, 20]) {
            await marketDAI.repayAtMaturity(
              futurePools(1)[0],
              parseUnits("0.000000001"),
              parseUnits("0.000000002"),
              maria.address,
            );
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0] + 86_400 * days]);
          }
        });

        it("THEN Maria owes (accountSnapshot) 5k + approx 2.8k DAI in penalties (no debt was compounded)", async () => {
          await provider.send("evm_mine", []);
          expect(await marketDAI.previewDebt(maria.address)).to.be.closeTo(
            parseUnits("5000") + ((parseUnits("5000") * penaltyRate) / parseUnits("1")) * 86_400n * 20n,
            parseUnits("0.00000001"),
          );
        });
      });
    });

    describe("Operations in more than one pool", () => {
      describe("GIVEN a smart pool supply of 100 AND a borrow of 30 in a first maturity pool", () => {
        beforeEach(async () => {
          await marketDAI.deposit(parseUnits("100"), maria.address);
          // make 9011 seconds to go by so the floatingAssetsAverage is equal to the floatingAssets
          await provider.send("evm_increaseTime", [9011]);

          await marketDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("30"),
            parseUnits("30"),
            maria.address,
            maria.address,
          );
        });

        it("WHEN a borrow of 70 is made to the second mp, THEN it should not revert", async () => {
          await expect(
            marketDAI.borrowAtMaturity(
              futurePools(2)[1],
              parseUnits("70"),
              parseUnits("70"),
              maria.address,
              maria.address,
            ),
          ).to.not.be.reverted;
        });

        it("WHEN a borrow of 70.01 is made to the second mp, THEN it should fail with error InsufficientProtocolLiquidity", async () => {
          await expect(
            marketDAI.borrowAtMaturity(
              futurePools(2)[1],
              parseUnits("70.01"),
              parseUnits("70.01"),
              maria.address,
              maria.address,
            ),
          ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
        });

        describe("AND GIVEN a deposit to the first mp of 30 AND a borrow of 70 in the second mp", () => {
          beforeEach(async () => {
            await marketDAI.depositAtMaturity(futurePools(1)[0], parseUnits("30"), parseUnits("30"), maria.address);
            await marketDAI.borrowAtMaturity(
              futurePools(2)[1],
              parseUnits("70"),
              parseUnits("70"),
              maria.address,
              maria.address,
            );
          });

          it("WHEN a borrow of 30 is made to the first mp, THEN it should not revert", async () => {
            await expect(
              marketDAI.borrowAtMaturity(
                futurePools(1)[0],
                parseUnits("30"),
                parseUnits("30"),
                maria.address,
                maria.address,
              ),
            ).to.not.be.reverted;
          });

          it("WHEN a borrow of 30.01 is made to the first mp, THEN it should fail with error InsufficientProtocolLiquidity", async () => {
            await expect(
              marketDAI.borrowAtMaturity(
                futurePools(1)[0],
                parseUnits("31"),
                parseUnits("31"),
                maria.address,
                maria.address,
              ),
            ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
          });

          describe("AND GIVEN a flexible borrow of 15", () => {
            beforeEach(async () => {
              await marketDAI.borrow(parseUnits("15"), maria.address, maria.address);
            });

            it("WHEN a borrow of 15 is made to the first mp, THEN it should not revert", async () => {
              await expect(
                marketDAI.borrowAtMaturity(
                  futurePools(1)[0],
                  parseUnits("15"),
                  parseUnits("15"),
                  maria.address,
                  maria.address,
                ),
              ).to.not.be.reverted;
            });

            it("WHEN a borrow of 15.01 is made to the first mp, THEN it should fail with error InsufficientProtocolLiquidity", async () => {
              await expect(
                marketDAI.borrowAtMaturity(
                  futurePools(1)[0],
                  parseUnits("15.01"),
                  parseUnits("15.01"),
                  maria.address,
                  maria.address,
                ),
              ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
            });

            describe("AND GIVEN a deposit to the first mp of 100", () => {
              beforeEach(async () => {
                await marketDAI.borrow(parseUnits("15"), maria.address, maria.address);
              });
            });

            describe("AND GIVEN a deposit of 100 in the first mp", () => {
              beforeEach(async () => {
                await marketDAI.depositAtMaturity(
                  futurePools(1)[0],
                  parseUnits("100"),
                  parseUnits("100"),
                  maria.address,
                );
              });

              it("WHEN a borrow of 15 is made to the flexible pool, THEN it should not revert", async () => {
                await expect(marketDAI.borrow(parseUnits("15"), maria.address, maria.address)).to.not.be.reverted;
              });

              it("WHEN a borrow of 15 is made to the second mp, THEN it should not revert", async () => {
                await expect(
                  marketDAI.borrowAtMaturity(
                    futurePools(2)[1],
                    parseUnits("15"),
                    parseUnits("15"),
                    maria.address,
                    maria.address,
                  ),
                ).to.not.be.reverted;
              });

              it("WHEN a borrow of 115 is made to the first mp, THEN it should not revert", async () => {
                await expect(
                  marketDAI.borrowAtMaturity(
                    futurePools(1)[0],
                    parseUnits("115"),
                    parseUnits("115"),
                    maria.address,
                    maria.address,
                  ),
                ).to.not.be.reverted;
              });

              it("WHEN a borrow of 15.01 is made to the second mp, THEN it should fail with error InsufficientProtocolLiquidity", async () => {
                await expect(
                  marketDAI.borrowAtMaturity(
                    futurePools(2)[1],
                    parseUnits("15.01"),
                    parseUnits("15.01"),
                    maria.address,
                    maria.address,
                  ),
                ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
              });

              it("WHEN a borrow of 115.01 is made to the first mp, THEN it should fail with error InsufficientProtocolLiquidity", async () => {
                await expect(
                  marketDAI.borrowAtMaturity(
                    futurePools(1)[0],
                    parseUnits("115.01"),
                    parseUnits("115.01"),
                    maria.address,
                    maria.address,
                  ),
                ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
              });

              it("WHEN a borrow of 15.01 is made to the flexible pool, THEN it should fail with error InsufficientProtocolLiquidity", async () => {
                await expect(
                  marketDAI.borrow(parseUnits("15.01"), maria.address, maria.address),
                ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
              });
            });
          });

          describe("AND GIVEN a borrow of 30 in the first mp", () => {
            beforeEach(async () => {
              await marketDAI.borrowAtMaturity(
                futurePools(1)[0],
                parseUnits("30"),
                parseUnits("30"),
                maria.address,
                maria.address,
              );
            });

            it("WHEN a withdraw of 30 is made to the first mp, THEN it should revert", async () => {
              await expect(
                marketDAI.withdrawAtMaturity(
                  futurePools(1)[0],
                  parseUnits("30"),
                  parseUnits("30"),
                  maria.address,
                  maria.address,
                ),
              ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
            });

            it("AND WHEN a supply of 30 is added to the sp, THEN the withdraw of 30 is not reverted", async () => {
              await marketDAI.deposit(parseUnits("30"), maria.address);
              await provider.send("evm_increaseTime", [9_011]);
              await expect(
                marketDAI.withdrawAtMaturity(
                  futurePools(1)[0],
                  parseUnits("30"),
                  parseUnits("30"),
                  maria.address,
                  maria.address,
                ),
              ).to.not.be.reverted;
            });

            it("AND WHEN a deposit of 30 is added to the mp, THEN the withdraw of 30 is not reverted", async () => {
              await marketDAI.depositAtMaturity(futurePools(1)[0], parseUnits("30"), parseUnits("30"), maria.address);
              await expect(
                marketDAI.withdrawAtMaturity(
                  futurePools(1)[0],
                  parseUnits("30"),
                  parseUnits("30"),
                  maria.address,
                  maria.address,
                ),
              ).to.not.be.reverted;
            });

            describe("AND GIVEN a smart pool supply of 30 AND a flexible borrow of 15", () => {
              beforeEach(async () => {
                await marketDAI.deposit(parseUnits("30"), maria.address);
                await provider.send("evm_increaseTime", [9_011]);
                await marketDAI.borrow(parseUnits("15"), maria.address, maria.address);
              });

              it("WHEN a withdraw of 15 is made to the first mp, THEN it should not revert", async () => {
                await expect(
                  marketDAI.withdrawAtMaturity(
                    futurePools(1)[0],
                    parseUnits("15"),
                    parseUnits("15"),
                    maria.address,
                    maria.address,
                  ),
                ).to.not.be.reverted;
              });

              it("WHEN a withdraw of 15.01 is made to the first mp, THEN it should revert", async () => {
                await expect(
                  marketDAI.withdrawAtMaturity(
                    futurePools(1)[0],
                    parseUnits("15.01"),
                    parseUnits("15.01"),
                    maria.address,
                    maria.address,
                  ),
                ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
              });

              it("AND WHEN a supply of 0.01 is added to the sp, THEN the withdraw of 15.01 is not reverted", async () => {
                await marketDAI.deposit(parseUnits("0.01"), maria.address);
                await provider.send("evm_increaseTime", [9_011]);
                await expect(
                  marketDAI.withdrawAtMaturity(
                    futurePools(1)[0],
                    parseUnits("15.01"),
                    parseUnits("15.01"),
                    maria.address,
                    maria.address,
                  ),
                ).to.not.be.reverted;
              });

              it("AND WHEN a deposit of 0.01 is added to the mp, THEN the withdraw of 15.01 is not reverted", async () => {
                await marketDAI.depositAtMaturity(
                  futurePools(1)[0],
                  parseUnits("0.01"),
                  parseUnits("0.01"),
                  maria.address,
                );
                await expect(
                  marketDAI.withdrawAtMaturity(
                    futurePools(1)[0],
                    parseUnits("15.01"),
                    parseUnits("15.01"),
                    maria.address,
                    maria.address,
                  ),
                ).to.not.be.reverted;
              });

              it("AND WHEN a smart pool repay of 0.01 is done, THEN the withdraw of 15.01 is not reverted", async () => {
                await marketDAI.refund(parseUnits("0.01"), maria.address);
                await expect(
                  marketDAI.withdrawAtMaturity(
                    futurePools(1)[0],
                    parseUnits("15.01"),
                    parseUnits("15.01"),
                    maria.address,
                    maria.address,
                  ),
                ).to.not.be.reverted;
              });

              it("AND WHEN a repay in the first maturity of 0.01 is done, THEN the withdraw of 15.01 is not reverted", async () => {
                await marketDAI.repayAtMaturity(
                  futurePools(1)[0],
                  parseUnits("0.01"),
                  parseUnits("0.01"),
                  maria.address,
                );
                await expect(
                  marketDAI.withdrawAtMaturity(
                    futurePools(1)[0],
                    parseUnits("15.01"),
                    parseUnits("15.01"),
                    maria.address,
                    maria.address,
                  ),
                ).to.not.be.reverted;
              });

              it("AND WHEN a repay in the second maturity of 0.01 is done, THEN the withdraw of 15.01 is not reverted", async () => {
                await marketDAI.repayAtMaturity(
                  futurePools(2)[1],
                  parseUnits("0.01"),
                  parseUnits("0.01"),
                  maria.address,
                );
                await expect(
                  marketDAI.withdrawAtMaturity(
                    futurePools(1)[0],
                    parseUnits("15.01"),
                    parseUnits("15.01"),
                    maria.address,
                    maria.address,
                  ),
                ).to.not.be.reverted;
              });
            });
          });
        });
      });
    });

    describe("Smart Pool Reserve", () => {
      describe("GIVEN a sp total supply of 100, a 10% smart pool reserve and a borrow for 80", () => {
        beforeEach(async () => {
          await marketDAI.deposit(parseUnits("100"), maria.address);
          // make 9011 seconds to go by so the floatingAssetsAverage is equal to the floatingAssets
          await provider.send("evm_increaseTime", [9011]);

          await timelockExecute(owner, marketDAI, "setReserveFactor", [parseUnits("0.1")]);
          await marketDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("80"),
            parseUnits("80"),
            maria.address,
            maria.address,
          );
        });

        it("AND WHEN trying to borrow 10 more, THEN it should not revert", async () => {
          await expect(
            marketDAI.borrowAtMaturity(
              futurePools(1)[0],
              parseUnits("10"),
              parseUnits("10"),
              maria.address,
              maria.address,
            ),
          ).to.not.be.reverted;
        });

        it("AND WHEN trying to borrow 10.01 more, THEN it should revert with InsufficientProtocolLiquidity", async () => {
          await expect(
            marketDAI.borrowAtMaturity(
              futurePools(1)[0],
              parseUnits("10.01"),
              parseUnits("10.01"),
              maria.address,
              maria.address,
            ),
          ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
        });

        it("AND WHEN depositing 0.1 more to the sp, THEN it should not revert when trying to borrow 10.01 more", async () => {
          await marketDAI.deposit(parseUnits("0.1"), maria.address);
          await expect(
            marketDAI.borrowAtMaturity(
              futurePools(1)[0],
              parseUnits("10.01"),
              parseUnits("10.01"),
              maria.address,
              maria.address,
            ),
          ).to.not.be.reverted;
        });

        describe("AND GIVEN a deposit of 10 to the maturity pool", () => {
          beforeEach(async () => {
            await marketDAI.depositAtMaturity(futurePools(1)[0], parseUnits("10"), parseUnits("10"), maria.address);
          });

          it("AND WHEN trying to borrow 20 more, THEN it should not revert", async () => {
            await expect(
              marketDAI.borrowAtMaturity(
                futurePools(1)[0],
                parseUnits("20"),
                parseUnits("20"),
                maria.address,
                maria.address,
              ),
            ).to.not.be.reverted;
          });

          describe("AND GIVEN a borrow of 10 to the maturity pool AND a withdraw of 10", () => {
            beforeEach(async () => {
              await marketDAI.borrowAtMaturity(
                futurePools(1)[0],
                parseUnits("10"),
                parseUnits("10"),
                maria.address,
                maria.address,
              );
              await marketDAI.withdrawAtMaturity(
                futurePools(1)[0],
                parseUnits("10"),
                parseUnits("10"),
                maria.address,
                maria.address,
              );
            });

            it("AND WHEN trying to borrow 0.01 more, THEN it should revert with InsufficientProtocolLiquidity", async () => {
              await expect(
                marketDAI.borrowAtMaturity(
                  futurePools(1)[0],
                  parseUnits("0.01"),
                  parseUnits("0.01"),
                  maria.address,
                  maria.address,
                ),
              ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
            });

            describe("AND GIVEN a repay of 5", () => {
              beforeEach(async () => {
                await marketDAI.repayAtMaturity(futurePools(1)[0], parseUnits("5"), parseUnits("5"), maria.address);
              });

              it("WHEN trying to borrow 5 more, THEN it should not revert", async () => {
                await expect(
                  marketDAI.borrowAtMaturity(
                    futurePools(1)[0],
                    parseUnits("5"),
                    parseUnits("5"),
                    maria.address,
                    maria.address,
                  ),
                ).to.not.be.reverted;
              });

              it("AND WHEN trying to borrow 5.01 more, THEN it should revert with InsufficientProtocolLiquidity", async () => {
                await expect(
                  marketDAI.borrowAtMaturity(
                    futurePools(1)[0],
                    parseUnits("5.01"),
                    parseUnits("5.01"),
                    maria.address,
                    maria.address,
                  ),
                ).to.be.revertedWithCustomError(marketDAI, "InsufficientProtocolLiquidity");
              });
            });
          });
        });
      });
    });
  });
});
