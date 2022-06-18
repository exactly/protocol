import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { BigNumber, ContractTransaction } from "ethers";
import type { Auditor, FixedLender, InterestRateModel, MockERC20, WETH } from "../types";
import timelockExecute from "./utils/timelockExecute";
import futurePools from "./utils/futurePools";
import { decodeMaturities } from "./exactlyUtils";

const {
  utils: { parseUnits },
  getUnnamedSigners,
  getNamedSigner,
  getContract,
  provider,
} = ethers;

describe("FixedLender", function () {
  let dai: MockERC20;
  let weth: WETH;
  let auditor: Auditor;
  let fixedLenderDAI: FixedLender;
  let fixedLenderWETH: FixedLender;
  let interestRateModel: InterestRateModel;

  let maria: SignerWithAddress;
  let john: SignerWithAddress;
  let owner: SignerWithAddress;
  let penaltyRate: BigNumber;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [maria, john] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture(["Markets"]);

    dai = await getContract<MockERC20>("DAI", maria);
    weth = await getContract<WETH>("WETH", maria);
    auditor = await getContract<Auditor>("Auditor", maria);
    fixedLenderDAI = await getContract<FixedLender>("FixedLenderDAI", maria);
    fixedLenderWETH = await getContract<FixedLender>("FixedLenderWETH", maria);
    interestRateModel = await getContract<InterestRateModel>("InterestRateModel", owner);
    penaltyRate = await fixedLenderDAI.penaltyRate();

    await timelockExecute(owner, interestRateModel, "setCurveParameters", [0, 0, parseUnits("6"), parseUnits("2")]);
    await timelockExecute(owner, interestRateModel, "setSPFeeRate", [0]);
    await timelockExecute(owner, fixedLenderDAI, "setSmartPoolReserveFactor", [0]);
    for (const signer of [maria, john]) {
      await dai.connect(owner).mint(signer.address, parseUnits("10000"));
      await dai.connect(signer).approve(fixedLenderDAI.address, parseUnits("10000"));
      await weth.deposit({ value: parseUnits("10") });
      await weth.approve(fixedLenderWETH.address, parseUnits("10"));
    }
  });

  describe("small positions", () => {
    describe("WHEN depositing 2wei of a dai", () => {
      beforeEach(async () => {
        await fixedLenderDAI.deposit(2, maria.address);
        // we add liquidity to the maturity
        await fixedLenderDAI.depositAtMaturity(futurePools(1)[0], 2, 0, maria.address);
      });
      it("THEN the FixedLender registers a supply of 2 wei DAI for the user (exposed via getAccountSnapshot)", async () => {
        expect((await fixedLenderDAI.getAccountSnapshot(maria.address, futurePools(1)[0]))[0]).to.equal(2);
      });
      it("AND the Market Size of the smart pool is 2 wei of a dai", async () => {
        expect(await fixedLenderDAI.totalAssets()).to.equal(2);
      });
      it("AND its not possible to borrow 2 wei of a dai", async () => {
        await expect(
          fixedLenderDAI.borrowAtMaturity(futurePools(1)[0], 2, 2, maria.address, maria.address),
        ).to.be.revertedWith("InsufficientLiquidity()");
      });
      describe("AND WHEN borrowing 1 wei of DAI", () => {
        let tx: ContractTransaction;
        beforeEach(async () => {
          tx = await fixedLenderDAI.borrowAtMaturity(futurePools(1)[0], 1, 1, maria.address, maria.address);
        });
        it("THEN a BorrowAtMaturity event is emitted", async () => {
          await expect(tx)
            .to.emit(fixedLenderDAI, "BorrowAtMaturity")
            .withArgs(futurePools(1)[0], maria.address, maria.address, maria.address, 1, 0);
        });
        it("AND the Market Size of the smart pool remains in 2 wei of a dai", async () => {
          expect(await fixedLenderDAI.totalAssets()).to.be.equal(2);
        });
        it("AND a 1 wei of DAI borrow is registered", async () => {
          expect((await fixedLenderDAI.fixedPools(futurePools(1)[0]))[0]).to.equal(1);
        });
      });
    });
  });

  describe("WHEN depositing 100 DAI to a maturity pool", () => {
    let tx: ContractTransaction;
    beforeEach(async () => {
      tx = await fixedLenderDAI.depositAtMaturity(
        futurePools(1)[0],
        parseUnits("100"),
        parseUnits("100"),
        maria.address,
      );
    });
    it("THEN a DepositAtMaturity event is emitted", async () => {
      await expect(tx)
        .to.emit(fixedLenderDAI, "DepositAtMaturity")
        .withArgs(futurePools(1)[0], maria.address, maria.address, parseUnits("100"), 0);
    });
    it("AND the FixedLender contract has a balance of 100 DAI", async () => {
      expect(await dai.balanceOf(fixedLenderDAI.address)).to.equal(parseUnits("100"));
    });
    it("AND the FixedLender registers a supply of 100 DAI for the user", async () => {
      expect((await fixedLenderDAI.fixedDepositPositions(futurePools(1)[0], maria.address))[0]).to.equal(
        parseUnits("100"),
      );
    });
    it("WHEN trying to borrow DAI THEN it reverts with INSUFFICIENT_LIQUIDITY since collateral was not deposited yet", async () => {
      await expect(
        fixedLenderDAI.borrowAtMaturity(futurePools(1)[0], 1000, 2000, maria.address, maria.address),
      ).to.be.revertedWith("InsufficientLiquidity()");
    });
    describe("AND WHEN depositing 50 DAI to the same maturity, as the same user", () => {
      beforeEach(async () => {
        tx = await fixedLenderDAI.depositAtMaturity(
          futurePools(1)[0],
          parseUnits("50"),
          parseUnits("50"),
          maria.address,
        );
      });
      it("THEN a DepositAtMaturity event is emitted", async () => {
        await expect(tx)
          .to.emit(fixedLenderDAI, "DepositAtMaturity")
          .withArgs(futurePools(1)[0], maria.address, maria.address, parseUnits("50"), 0);
      });
      it("AND the FixedLender contract has a balance of 150 DAI", async () => {
        expect(await dai.balanceOf(fixedLenderDAI.address)).to.equal(parseUnits("150"));
      });
      it("AND the FixedLender does not register a smart pool balance deposit (exposed via getAccountSnapshot)", async () => {
        expect((await fixedLenderDAI.getAccountSnapshot(maria.address, futurePools(1)[0]))[0]).to.equal(0);
      });
    });

    describe("WHEN depositing collateral and borrowing 60 DAI from the same maturity", () => {
      beforeEach(async () => {
        await fixedLenderDAI.deposit(parseUnits("100"), maria.address);
        tx = await fixedLenderDAI.borrowAtMaturity(
          futurePools(1)[0],
          parseUnits("60"),
          parseUnits("66"),
          maria.address,
          maria.address,
        );
      });
      it("THEN a BorrowAtMaturity event is emitted", async () => {
        await expect(tx)
          .to.emit(fixedLenderDAI, "BorrowAtMaturity")
          .withArgs(futurePools(1)[0], maria.address, maria.address, maria.address, parseUnits("60"), 0);
      });
      it("AND a 60 DAI borrow is registered", async () => {
        expect((await fixedLenderDAI.fixedPools(futurePools(1)[0]))[0]).to.equal(parseUnits("60"));
      });
      it("AND contract's state variable fixedBorrows registers the maturity where the user borrowed from", async () => {
        const maturities = await fixedLenderDAI.fixedBorrows(maria.address);
        expect(decodeMaturities(maturities)).contains(futurePools(1)[0].toNumber());
      });
      describe("AND WHEN trying to repay 100 (too much)", () => {
        let balanceBefore: BigNumber;

        beforeEach(async () => {
          balanceBefore = await dai.balanceOf(maria.address);
          await fixedLenderDAI.repayAtMaturity(futurePools(1)[0], parseUnits("100"), parseUnits("100"), maria.address);
        });
        it("THEN all debt is repaid", async () => {
          expect((await fixedLenderDAI.getAccountSnapshot(maria.address, futurePools(1)[0]))[1]).to.equal(0);
        });
        it("THEN the 40 spare amount is not discounted from the user balance", async () => {
          expect(await dai.balanceOf(maria.address)).to.equal(balanceBefore.sub(parseUnits("60")));
        });
      });
      describe("AND WHEN borrowing 60 DAI from another maturity AND repaying only first debt", () => {
        beforeEach(async () => {
          await fixedLenderDAI.deposit(parseUnits("1000"), maria.address);
          const { blockNumber } = await tx.wait();
          const { timestamp } = await provider.getBlock(blockNumber);
          await provider.send("evm_setNextBlockTimestamp", [timestamp + 218]);
          await fixedLenderDAI.borrowAtMaturity(
            futurePools(2)[1],
            parseUnits("60"),
            parseUnits("60"),
            maria.address,
            maria.address,
          );
          await fixedLenderDAI.repayAtMaturity(futurePools(1)[0], parseUnits("60"), parseUnits("60"), maria.address);
        });
        it("THEN contract's state variable fixedBorrows registers the second maturity where the user borrowed from", async () => {
          const maturities = await fixedLenderDAI.fixedBorrows(maria.address);
          expect(decodeMaturities(maturities)).contains(futurePools(2)[1].toNumber());
        });
      });
      describe("AND WHEN fully repaying the debt", () => {
        beforeEach(async () => {
          tx = await fixedLenderDAI.repayAtMaturity(
            futurePools(1)[0],
            parseUnits("60"),
            parseUnits("60"),
            maria.address,
          );
        });
        it("THEN a RepayAtMaturity event is emitted", async () => {
          await expect(tx)
            .to.emit(fixedLenderDAI, "RepayAtMaturity")
            .withArgs(futurePools(1)[0], maria.address, maria.address, parseUnits("60"), parseUnits("60"));
        });
        it("AND contract's state variable fixedBorrows does not register the maturity where the user borrowed from anymore", async () => {
          const maturities = await fixedLenderDAI.fixedBorrows(maria.address);
          expect(decodeMaturities(maturities).length).eq(0);
        });
        describe("AND WHEN withdrawing collateral and maturity pool deposit", () => {
          beforeEach(async () => {
            await fixedLenderDAI.withdraw(parseUnits("100"), maria.address, maria.address);
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + 1]);
            await fixedLenderDAI.withdrawAtMaturity(
              futurePools(1)[0],
              parseUnits("100"),
              parseUnits("100"),
              maria.address,
              maria.address,
            );
          });
          it("THEN the collateral & deposits are returned to Maria (10000)", async () => {
            expect(await dai.balanceOf(maria.address)).to.equal(parseUnits("10000"));
            expect(await dai.balanceOf(fixedLenderDAI.address)).to.equal(0);
          });
          it("AND contract's state variable fixedDeposits does not register the maturity where the user deposited to anymore", async () => {
            const maturities = await fixedLenderDAI.fixedDeposits(maria.address);
            expect(decodeMaturities(maturities).length).eq(0);
          });
        });

        describe("AND WHEN withdrawing MORE from maturity pool than maria has", () => {
          beforeEach(async () => {
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + 1]);
            await fixedLenderDAI.withdrawAtMaturity(
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
          it("AND contract's state variable fixedDeposits does not register the maturity where the user deposited to anymore", async () => {
            const maturities = await fixedLenderDAI.fixedDeposits(maria.address);
            expect(decodeMaturities(maturities).length).eq(0);
          });
        });

        describe("AND WHEN withdrawing LESS from maturity pool than maria has", () => {
          beforeEach(async () => {
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + 1]);
            await fixedLenderDAI.withdrawAtMaturity(
              futurePools(1)[0],
              parseUnits("50"),
              parseUnits("50"),
              maria.address,
              maria.address,
            );
          });
          it("THEN the total amount withdrawn is 9950 (leaving 150 in FixedLender / 100 in SP / 50 in MP)", async () => {
            expect(await dai.balanceOf(maria.address)).to.equal(parseUnits("9850"));
            expect(await dai.balanceOf(fixedLenderDAI.address)).to.equal(parseUnits("150"));
          });
        });
      });
      describe("GIVEN the maturity pool matures", () => {
        beforeEach(async () => {
          await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + 1]);
        });
        it("WHEN trying to withdraw an amount of zero THEN it reverts", async () => {
          await expect(
            fixedLenderDAI.withdrawAtMaturity(futurePools(1)[0], 0, 0, maria.address, maria.address),
          ).to.be.revertedWith("ZeroWithdraw()");
        });
      });

      describe("AND WHEN partially (40DAI, 66%) repaying the debt", () => {
        beforeEach(async () => {
          tx = await fixedLenderDAI.repayAtMaturity(
            futurePools(1)[0],
            parseUnits("40"),
            parseUnits("40"),
            maria.address,
          );
        });
        it("THEN a RepayAtMaturity event is emitted", async () => {
          await expect(tx)
            .to.emit(fixedLenderDAI, "RepayAtMaturity")
            .withArgs(futurePools(1)[0], maria.address, maria.address, parseUnits("40"), parseUnits("40"));
        });
        it("AND Maria still owes 20 DAI", async () => {
          expect((await fixedLenderDAI.getAccountSnapshot(maria.address, futurePools(1)[0]))[1]).to.equal(
            parseUnits("20"),
          );
        });

        describe("AND WHEN moving in time to 1 day after maturity", () => {
          let penalty: BigNumber;
          beforeEach(async () => {
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + 86_400]);
            penalty = parseUnits("20").mul(penaltyRate).div(parseUnits("1")).mul(86_400);
            expect(penalty).to.be.gt(0);
          });
          it("THEN Maria owes (getAccountSnapshot) 20 DAI of principal + (20*0.02 ~= 0.0400032 ) DAI of late payment penalties", async () => {
            await provider.send("evm_mine", []);
            expect((await fixedLenderDAI.getAccountSnapshot(maria.address, futurePools(1)[0]))[1]).to.equal(
              parseUnits("20").add(penalty),
            );
          });
          describe("AND WHEN repaying the rest of the 20.4 owed DAI", () => {
            beforeEach(async () => {
              const amount = parseUnits("20").add(penalty);
              await fixedLenderDAI.repayAtMaturity(futurePools(1)[0], amount, amount, maria.address);
            });
            it("THEN all debt is repaid", async () => {
              expect((await fixedLenderDAI.getAccountSnapshot(maria.address, futurePools(1)[0]))[1]).to.equal(0);
            });
          });
          describe("AND WHEN repaying more than what is owed (30 DAI)", () => {
            beforeEach(async () => {
              await fixedLenderDAI.repayAtMaturity(
                futurePools(1)[0],
                parseUnits("30"),
                parseUnits("30"),
                maria.address,
              );
            });
            it("THEN all debt is repaid", async () => {
              expect((await fixedLenderDAI.getAccountSnapshot(maria.address, futurePools(1)[0]))[1]).to.equal(0);
            });
          });
        });
      });
    });

    describe("AND WHEN moving in time to maturity AND withdrawing from the maturity pool", () => {
      beforeEach(async () => {
        await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + 1]);
        tx = await fixedLenderDAI.withdrawAtMaturity(
          futurePools(1)[0],
          parseUnits("100"),
          parseUnits("100"),
          maria.address,
          maria.address,
        );
      });
      it("THEN 100 DAI are returned to Maria", async () => {
        expect(await dai.balanceOf(maria.address)).to.equal(parseUnits("10000"));
        expect(await dai.balanceOf(fixedLenderDAI.address)).to.equal(0);
      });
      it("AND a WithdrawAtMaturity event is emitted", async () => {
        await expect(tx)
          .to.emit(fixedLenderDAI, "WithdrawAtMaturity")
          .withArgs(
            futurePools(1)[0],
            maria.address,
            maria.address,
            maria.address,
            parseUnits("100"),
            parseUnits("100"),
          );
      });
    });
  });

  describe("simple validations:", () => {
    it("WHEN calling setMaxFuturePools from a regular (non-admin) user, THEN it reverts with an AccessControl error", async () => {
      await expect(fixedLenderDAI.setMaxFuturePools(12)).to.be.revertedWith("AccessControl");
    });
    it("WHEN calling setMaxFuturePools, THEN the maxFuturePools should be updated", async () => {
      await timelockExecute(owner, fixedLenderDAI, "setMaxFuturePools", [15]);
      expect(await fixedLenderDAI.maxFuturePools()).to.be.equal(15);
    });
    it("WHEN calling setAccumulatedEarningsSmoothFactor from a regular (non-admin) user, THEN it reverts with an AccessControl error", async () => {
      await expect(fixedLenderDAI.setAccumulatedEarningsSmoothFactor(parseUnits("2"))).to.be.revertedWith(
        "AccessControl",
      );
    });
    it("WHEN calling setAccumulatedEarningsSmoothFactor, THEN the accumulatedEarningsSmoothFactor should be updated", async () => {
      await timelockExecute(owner, fixedLenderDAI, "setAccumulatedEarningsSmoothFactor", [parseUnits("2")]);
      expect(await fixedLenderDAI.accumulatedEarningsSmoothFactor()).to.be.equal(parseUnits("2"));
    });
  });

  describe("GIVEN an interest rate of 2%", () => {
    beforeEach(async () => {
      await timelockExecute(owner, interestRateModel, "setCurveParameters", [
        0,
        parseUnits("0.02"),
        parseUnits("6"),
        parseUnits("2"),
      ]);
      await fixedLenderDAI.deposit(parseUnits("1"), maria.address);
      await auditor.enterMarket(fixedLenderDAI.address);
      // we add liquidity to the maturity
      await fixedLenderDAI.depositAtMaturity(futurePools(1)[0], parseUnits("1"), parseUnits("1"), maria.address);
    });
    it("WHEN trying to borrow 0.8 DAI with a max amount of debt of 0.8 DAI, THEN it reverts with TOO_MUCH_SLIPPAGE", async () => {
      await expect(
        fixedLenderDAI.borrowAtMaturity(
          futurePools(1)[0],
          parseUnits("0.8"),
          parseUnits("0.8"),
          maria.address,
          maria.address,
        ),
      ).to.be.revertedWith("TooMuchSlippage()");
    });
    it("AND contract's state variable fixedDeposits registers the maturity where the user supplied to", async () => {
      const maturities = await fixedLenderDAI.fixedDeposits(maria.address);
      expect(decodeMaturities(maturities)).contains(futurePools(1)[0].toNumber());
    });
    it("WHEN trying to deposit 100 DAI with a minimum required amount to be received of 103, THEN 102 are received instead AND the transaction reverts with TOO_MUCH_SLIPPAGE", async () => {
      await expect(
        fixedLenderDAI.depositAtMaturity(futurePools(1)[0], parseUnits("100"), parseUnits("103"), maria.address),
      ).to.be.revertedWith("TooMuchSlippage()");
    });
  });

  describe("GIVEN John deposited 12 DAI to the smart pool AND Maria borrowed 6 DAI from an empty maturity", () => {
    beforeEach(async () => {
      await fixedLenderWETH.deposit(parseUnits("10"), maria.address);
      await auditor.enterMarket(fixedLenderWETH.address);

      await timelockExecute(owner, interestRateModel, "setCurveParameters", [
        parseUnits("0"),
        parseUnits("0"),
        parseUnits("1.1"),
        parseUnits("1"),
      ]);
      const tx = await fixedLenderDAI.connect(john).deposit(parseUnits("12"), maria.address);
      const { blockNumber } = await tx.wait();
      const { timestamp } = await provider.getBlock(blockNumber);
      await provider.send("evm_setNextBlockTimestamp", [timestamp + 9011]);

      await fixedLenderDAI.borrowAtMaturity(
        futurePools(1)[0],
        parseUnits("6"),
        parseUnits("6"),
        maria.address,
        maria.address,
      );
    });
    it("WHEN Maria tries to borrow 5.99 more DAI on the same maturity, THEN it does not revert", async () => {
      await expect(
        fixedLenderDAI.borrowAtMaturity(
          futurePools(1)[0],
          parseUnits("5.99"),
          parseUnits("5.99"),
          maria.address,
          maria.address,
        ),
      ).to.not.be.reverted;
    });
    it("WHEN Maria tries to borrow 6 more DAI on the same maturity (remaining liquidity), THEN it does not revert", async () => {
      await expect(
        fixedLenderDAI.borrowAtMaturity(
          futurePools(1)[0],
          parseUnits("6"),
          parseUnits("6"),
          maria.address,
          maria.address,
        ),
      ).to.not.be.reverted;
    });
    it("WHEN Maria tries to borrow 6.01 more DAI on another maturity, THEN it fails with InsufficientProtocolLiquidity", async () => {
      await expect(
        fixedLenderDAI.borrowAtMaturity(
          futurePools(2)[1],
          parseUnits("6.01"),
          parseUnits("7"),
          maria.address,
          maria.address,
        ),
      ).to.be.revertedWith("InsufficientProtocolLiquidity()");
    });
    it("WHEN Maria tries to borrow 12 more DAI on the same maturity, THEN it fails with UtilizationExceeded", async () => {
      await expect(
        fixedLenderDAI.borrowAtMaturity(
          futurePools(1)[0],
          parseUnits("12"),
          parseUnits("12"),
          maria.address,
          maria.address,
        ),
      ).to.be.revertedWith("UtilizationExceeded()");
    });
    describe("AND John deposited 2388 DAI to the smart pool", () => {
      beforeEach(async () => {
        const tx = await fixedLenderDAI.connect(john).deposit(parseUnits("2388"), maria.address);
        const { blockNumber } = await tx.wait();
        const { timestamp } = await provider.getBlock(blockNumber);
        await provider.send("evm_setNextBlockTimestamp", [timestamp + 218]);
      });
      it("WHEN Maria tries to borrow 2500 DAI, THEN it fails with UtilizationExceeded", async () => {
        await expect(
          fixedLenderDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("2500"),
            parseUnits("5000"),
            maria.address,
            maria.address,
          ),
        ).to.be.revertedWith("UtilizationExceeded");
      });
      it("WHEN Maria tries to borrow 150 DAI, THEN it succeeds", async () => {
        await expect(
          fixedLenderDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("150"),
            parseUnits("150"),
            maria.address,
            maria.address,
          ),
        ).to.not.be.reverted;
      });
    });
    describe("AND John deposited 100 DAI to maturity", () => {
      beforeEach(async () => {
        await fixedLenderDAI
          .connect(john)
          .depositAtMaturity(futurePools(1)[0], parseUnits("100"), parseUnits("100"), john.address);
      });
      it("WHEN Maria tries to borrow 150 DAI, THEN it fails with UtilizationExceeded", async () => {
        await expect(
          fixedLenderDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("150"),
            parseUnits("150"),
            maria.address,
            maria.address,
          ),
        ).to.be.revertedWith("UtilizationExceeded()");
      });
      describe("AND John deposited 1200 DAI to the smart pool", () => {
        beforeEach(async () => {
          await fixedLenderDAI
            .connect(john)
            .depositAtMaturity(futurePools(1)[0], parseUnits("1200"), parseUnits("1200"), john.address);
        });
        it("WHEN Maria tries to borrow 1350 DAI, THEN it fails with UtilizationExceeded", async () => {
          await expect(
            fixedLenderDAI.borrowAtMaturity(
              futurePools(1)[0],
              parseUnits("1350"),
              parseUnits("2000"),
              maria.address,
              maria.address,
            ),
          ).to.be.revertedWith("UtilizationExceeded()");
        });
        it("WHEN Maria tries to borrow 200 DAI, THEN it succeeds", async () => {
          await expect(
            fixedLenderDAI.borrowAtMaturity(
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
            fixedLenderDAI.borrowAtMaturity(
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
      await fixedLenderWETH.deposit(parseUnits("10"), maria.address);
      await auditor.enterMarket(fixedLenderDAI.address);
      await auditor.enterMarket(fixedLenderWETH.address);
    });
    describe("AND GIVEN she deposits 1000DAI into the next two maturity pools AND other 500 into the smart pool", () => {
      beforeEach(async () => {
        for (const pool of futurePools(2)) {
          await fixedLenderDAI.depositAtMaturity(pool, parseUnits("1000"), parseUnits("1000"), maria.address);
        }
        await fixedLenderDAI.deposit(parseUnits("6000"), maria.address);
      });
      describe("WHEN borrowing 1200 in the current maturity", () => {
        beforeEach(async () => {
          await fixedLenderDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("1200"),
            parseUnits("1200"),
            maria.address,
            maria.address,
          );
        });
        it("THEN all of the maturity pools funds are in use", async () => {
          const [borrowed, supplied] = await fixedLenderDAI.fixedPools(futurePools(1)[0]);
          expect(borrowed).to.gt(supplied);
        });
        it("AND 200 are borrowed from the smart pool", async () => {
          expect(await fixedLenderDAI.smartPoolBorrowed()).to.equal(parseUnits("200"));
        });
        it("AND WHEN trying to withdraw 300 ==(500 available, 200 borrowed to MP) from the smart pool, THEN it succeeds", async () => {
          await expect(fixedLenderDAI.withdraw(parseUnits("300"), maria.address, maria.address)).to.not.be.reverted;
        });
        it("AND WHEN trying to withdraw 5900 >(6000 total, 200 borrowed to MP) from the smart pool, THEN it reverts because 100 of those 5900 are still lent to the maturity pool", async () => {
          await expect(fixedLenderDAI.withdraw(parseUnits("5900"), maria.address, maria.address)).to.be.revertedWith(
            "InsufficientProtocolLiquidity()",
          );
        });
        describe("AND borrowing 1100 in a later maturity ", () => {
          beforeEach(async () => {
            await fixedLenderDAI.borrowAtMaturity(
              futurePools(2)[1],
              parseUnits("1100"),
              parseUnits("1100"),
              maria.address,
              maria.address,
            );
          });
          it("THEN all of the maturity pools funds are in use", async () => {
            const [borrowed, supplied] = await fixedLenderDAI.fixedPools(futurePools(2)[1]);
            expect(borrowed).to.gt(supplied);
          });
          it("THEN the later maturity owes 100 to the smart pool", async () => {
            const mp = await fixedLenderDAI.fixedPools(futurePools(2)[1]);
            expect(mp.borrowed.sub(mp.supplied)).to.equal(parseUnits("100"));
          });
          it("THEN the smart pool has lent 300 (100 from the later maturity one, 200 from the first one)", async () => {
            expect(await fixedLenderDAI.smartPoolBorrowed()).to.equal(parseUnits("300"));
          });
          describe("AND WHEN repaying 50 DAI in the later maturity", () => {
            beforeEach(async () => {
              await fixedLenderDAI.repayAtMaturity(
                futurePools(2)[1],
                parseUnits("50"),
                parseUnits("50"),
                maria.address,
              );
            });
            it("THEN 1050 DAI are borrowed", async () => {
              expect((await fixedLenderDAI.fixedPools(futurePools(2)[1])).borrowed).to.equal(parseUnits("1050"));
            });
            it("THEN the maturity pool doesn't have funds available", async () => {
              const [borrowed, supplied] = await fixedLenderDAI.fixedPools(futurePools(2)[1]);
              expect(borrowed).to.gt(supplied);
            });
            it("THEN the maturity pool owes 50 to the smart pool", async () => {
              const mp = await fixedLenderDAI.fixedPools(futurePools(2)[1]);
              expect(mp.borrowed.sub(mp.supplied)).to.equal(parseUnits("50"));
            });
            it("THEN the smart pool was repaid 50 DAI (SPborrowed=250)", async () => {
              expect(await fixedLenderDAI.smartPoolBorrowed()).to.equal(parseUnits("250"));
            });
          });
          describe("AND WHEN john deposits 800 to the later maturity", () => {
            beforeEach(async () => {
              await fixedLenderDAI
                .connect(john)
                .depositAtMaturity(futurePools(2)[1], parseUnits("800"), parseUnits("800"), john.address);
            });
            it("THEN 1100 DAI are still borrowed", async () => {
              expect((await fixedLenderDAI.fixedPools(futurePools(2)[1])).borrowed).to.equal(parseUnits("1100"));
            });
            it("THEN the later maturity has 700 DAI available for borrowing", async () => {
              const [borrowed, supplied] = await fixedLenderDAI.fixedPools(futurePools(2)[1]);
              expect(supplied.sub(borrowed)).to.equal(parseUnits("700"));
            });
            it("THEN the later maturity has no supply from the Smart Pool", async () => {
              const mp = await fixedLenderDAI.fixedPools(futurePools(2)[1]);
              expect(mp.supplied).to.gt(mp.borrowed);
            });
            it("THEN the smart pool was repaid, and is still owed 200 from the current one", async () => {
              expect(await fixedLenderDAI.smartPoolBorrowed()).to.equal(parseUnits("200"));
            });
          });
        });
        describe("AND WHEN john deposits 100 to the same maturity", () => {
          beforeEach(async () => {
            await fixedLenderDAI
              .connect(john)
              .depositAtMaturity(futurePools(1)[0], parseUnits("100"), parseUnits("100"), john.address);
          });
          it("THEN 1200 DAI are still borrowed", async () => {
            expect((await fixedLenderDAI.fixedPools(futurePools(1)[0])).borrowed).to.equal(parseUnits("1200"));
          });
          it("THEN the maturity pool still doesn't have funds available", async () => {
            const [borrowed, supplied] = await fixedLenderDAI.fixedPools(futurePools(1)[0]);
            expect(borrowed).to.gt(supplied);
          });
          it("THEN the maturity pool still owes 100 to the smart pool", async () => {
            const mp = await fixedLenderDAI.fixedPools(futurePools(1)[0]);
            expect(mp.borrowed.sub(mp.supplied)).to.equal(parseUnits("100"));
          });
          it("THEN the smart pool was repaid the other 100 (is owed still 100)", async () => {
            expect(await fixedLenderDAI.smartPoolBorrowed()).to.equal(parseUnits("100"));
          });
        });
        describe("AND WHEN john deposits 300 to the same maturity", () => {
          beforeEach(async () => {
            await fixedLenderDAI
              .connect(john)
              .depositAtMaturity(futurePools(1)[0], parseUnits("300"), parseUnits("300"), john.address);
          });
          it("THEN 1200 DAI are still borrowed", async () => {
            expect((await fixedLenderDAI.fixedPools(futurePools(1)[0])).borrowed).to.equal(parseUnits("1200"));
          });
          it("THEN the maturity pool has 100 DAI available", async () => {
            const [borrowed, supplied] = await fixedLenderDAI.fixedPools(futurePools(1)[0]);
            expect(supplied.sub(borrowed)).to.equal(parseUnits("100"));
          });
          it("THEN the maturity pool doesn't owe the Smart Pool", async () => {
            const mp = await fixedLenderDAI.fixedPools(futurePools(1)[0]);
            expect(mp.supplied).to.gt(mp.borrowed);
          });
        });
        describe("AND WHEN repaying 100 DAI", () => {
          beforeEach(async () => {
            await fixedLenderDAI.repayAtMaturity(
              futurePools(1)[0],
              parseUnits("100"),
              parseUnits("100"),
              maria.address,
            );
          });
          it("THEN 1100 DAI are still borrowed", async () => {
            expect((await fixedLenderDAI.fixedPools(futurePools(1)[0])).borrowed).to.equal(parseUnits("1100"));
          });
          it("THEN the maturity pool doesn't have funds available", async () => {
            const [borrowed, supplied] = await fixedLenderDAI.fixedPools(futurePools(1)[0]);
            expect(borrowed).to.gt(supplied);
          });
          it("THEN the maturity pool still owes 100 to the smart pool (100 repaid)", async () => {
            const mp = await fixedLenderDAI.fixedPools(futurePools(1)[0]);
            expect(mp.borrowed.sub(mp.supplied)).to.equal(parseUnits("100"));
          });
        });
        describe("AND WHEN repaying 300 DAI", () => {
          beforeEach(async () => {
            await fixedLenderDAI.repayAtMaturity(
              futurePools(1)[0],
              parseUnits("300"),
              parseUnits("300"),
              maria.address,
            );
          });
          it("THEN 900 DAI are still borrowed", async () => {
            expect((await fixedLenderDAI.fixedPools(futurePools(1)[0])).borrowed).to.equal(parseUnits("900"));
          });
          it("THEN the maturity pool has 100 DAI available", async () => {
            const [borrowed, supplied] = await fixedLenderDAI.fixedPools(futurePools(1)[0]);
            expect(supplied.sub(borrowed)).to.equal(parseUnits("100"));
          });
          it("THEN the maturity pool doesn't owe the Smart Pool", async () => {
            const mp = await fixedLenderDAI.fixedPools(futurePools(1)[0]);
            expect(mp.supplied).to.gt(mp.borrowed);
          });
        });
        describe("AND WHEN repaying in full (1200 DAI)", () => {
          beforeEach(async () => {
            await fixedLenderDAI.repayAtMaturity(
              futurePools(1)[0],
              parseUnits("1200"),
              parseUnits("1200"),
              maria.address,
            );
          });
          it("THEN the maturity pool has 1000 DAI available", async () => {
            const [borrowed, supplied] = await fixedLenderDAI.fixedPools(futurePools(1)[0]);
            expect(supplied.sub(borrowed)).to.equal(parseUnits("1000"));
          });
        });
      });
    });
    describe("AND GIVEN she borrows 5k DAI", () => {
      beforeEach(async () => {
        // we first fund the maturity pool so it has liquidity to borrow
        await fixedLenderDAI.depositAtMaturity(
          futurePools(1)[0],
          parseUnits("5000"),
          parseUnits("5000"),
          maria.address,
        );
        await fixedLenderDAI.borrowAtMaturity(
          futurePools(1)[0],
          parseUnits("5000"),
          parseUnits("5000"),
          maria.address,
          maria.address,
        );
      });
      describe("AND WHEN moving in time to 20 days after maturity", () => {
        beforeEach(async () => {
          await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + 86_400 * 20]);
        });
        it("THEN Maria owes (getAccountSnapshot) 5k + aprox 2.8k DAI in penalties", async () => {
          await provider.send("evm_mine", []);
          expect((await fixedLenderDAI.getAccountSnapshot(maria.address, futurePools(1)[0]))[1]).to.equal(
            parseUnits("5000").add(
              parseUnits("5000")
                .mul(penaltyRate)
                .div(parseUnits("1"))
                .mul(86_400 * 20),
            ),
          );
        });
      });
      describe("AND WHEN moving in time to 20 days after maturity but repaying really small amounts within some days", () => {
        beforeEach(async () => {
          for (const days of [5, 10, 15, 20]) {
            await fixedLenderDAI.repayAtMaturity(
              futurePools(1)[0],
              parseUnits("0.000000001"),
              parseUnits("0.000000002"),
              maria.address,
            );
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber() + 86_400 * days]);
          }
        });
        it("THEN Maria owes (getAccountSnapshot) 5k + aprox 2.8k DAI in penalties (no debt was compounded)", async () => {
          await provider.send("evm_mine", []);
          expect((await fixedLenderDAI.getAccountSnapshot(maria.address, futurePools(1)[0]))[1]).to.be.closeTo(
            parseUnits("5000").add(
              parseUnits("5000")
                .mul(penaltyRate)
                .div(parseUnits("1"))
                .mul(86_400 * 20),
            ),
            parseUnits("0.00000001"),
          );
        });
      });
    });
    describe("Operations in more than one pool", () => {
      describe("GIVEN a smart pool supply of 100 AND a borrow of 30 in a first maturity pool", () => {
        beforeEach(async () => {
          const tx = await fixedLenderDAI.deposit(parseUnits("100"), maria.address);
          // we make 9011 seconds to go by so the smartPoolAssetsAverage is equal to the smartPoolAssets
          const { blockNumber } = await tx.wait();
          const { timestamp } = await provider.getBlock(blockNumber);
          await provider.send("evm_setNextBlockTimestamp", [timestamp + 9011]);

          await fixedLenderDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("30"),
            parseUnits("30"),
            maria.address,
            maria.address,
          );
        });
        it("WHEN a borrow of 70 is made to the second mp, THEN it should not revert", async () => {
          await expect(
            fixedLenderDAI.borrowAtMaturity(
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
            fixedLenderDAI.borrowAtMaturity(
              futurePools(2)[1],
              parseUnits("70.01"),
              parseUnits("70.01"),
              maria.address,
              maria.address,
            ),
          ).to.be.revertedWith("InsufficientProtocolLiquidity()");
        });
        describe("AND GIVEN a deposit to the first mp of 30 AND a borrow of 70 in the second mp", () => {
          beforeEach(async () => {
            await fixedLenderDAI.depositAtMaturity(
              futurePools(1)[0],
              parseUnits("30"),
              parseUnits("30"),
              maria.address,
            );
            await fixedLenderDAI.borrowAtMaturity(
              futurePools(2)[1],
              parseUnits("70"),
              parseUnits("70"),
              maria.address,
              maria.address,
            );
          });
          it("WHEN a borrow of 30 is made to the first mp, THEN it should not revert", async () => {
            await expect(
              fixedLenderDAI.borrowAtMaturity(
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
              fixedLenderDAI.borrowAtMaturity(
                futurePools(1)[0],
                parseUnits("31"),
                parseUnits("31"),
                maria.address,
                maria.address,
              ),
            ).to.be.revertedWith("InsufficientProtocolLiquidity()");
          });
          describe("AND GIVEN a borrow of 30 in the first mp", () => {
            beforeEach(async () => {
              await fixedLenderDAI.borrowAtMaturity(
                futurePools(1)[0],
                parseUnits("30"),
                parseUnits("30"),
                maria.address,
                maria.address,
              );
            });
            it("WHEN a withdraw of 30 is made to the first mp, THEN it should revert", async () => {
              await expect(
                fixedLenderDAI.withdrawAtMaturity(
                  futurePools(1)[0],
                  parseUnits("30"),
                  parseUnits("30"),
                  maria.address,
                  maria.address,
                ),
              ).to.be.revertedWith("InsufficientProtocolLiquidity()");
            });
            it("AND WHEN a supply of 30 is added to the sp, THEN the withdraw of 30 is not reverted", async () => {
              await fixedLenderDAI.deposit(parseUnits("30"), maria.address);
              await expect(
                fixedLenderDAI.withdrawAtMaturity(
                  futurePools(1)[0],
                  parseUnits("30"),
                  parseUnits("30"),
                  maria.address,
                  maria.address,
                ),
              ).to.not.be.reverted;
            });
            it("AND WHEN a deposit of 30 is added to the mp, THEN the withdraw of 30 is not reverted", async () => {
              await fixedLenderDAI.depositAtMaturity(
                futurePools(1)[0],
                parseUnits("30"),
                parseUnits("30"),
                maria.address,
              );
              await expect(
                fixedLenderDAI.withdrawAtMaturity(
                  futurePools(1)[0],
                  parseUnits("30"),
                  parseUnits("30"),
                  maria.address,
                  maria.address,
                ),
              ).to.not.be.reverted;
            });
          });
        });
      });
    });
    describe("Smart Pool Reserve", () => {
      describe("GIVEN a sp total supply of 100, a 10% smart pool reserve and a borrow for 80", () => {
        let tx: any;
        beforeEach(async () => {
          const depositTx = await fixedLenderDAI.deposit(parseUnits("100"), maria.address);
          // we make 9011 seconds to go by so the smartPoolAssetsAverage is equal to the smartPoolAssets
          const { blockNumber } = await depositTx.wait();
          const { timestamp } = await provider.getBlock(blockNumber);
          await provider.send("evm_setNextBlockTimestamp", [timestamp + 9011]);

          await timelockExecute(owner, fixedLenderDAI, "setSmartPoolReserveFactor", [parseUnits("0.1")]);
          tx = fixedLenderDAI.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("80"),
            parseUnits("80"),
            maria.address,
            maria.address,
          );
        });
        it("THEN the borrow transaction should not revert", async () => {
          await expect(tx).to.not.be.reverted;
        });
        it("AND WHEN trying to borrow 10 more, THEN it should not revert", async () => {
          await expect(
            fixedLenderDAI.borrowAtMaturity(
              futurePools(1)[0],
              parseUnits("10"),
              parseUnits("10"),
              maria.address,
              maria.address,
            ),
          ).to.not.be.reverted;
        });
        it("AND WHEN trying to borrow 10.01 more, THEN it should revert with SmartPoolReserveExceeded", async () => {
          await expect(
            fixedLenderDAI.borrowAtMaturity(
              futurePools(1)[0],
              parseUnits("10.01"),
              parseUnits("10.01"),
              maria.address,
              maria.address,
            ),
          ).to.be.revertedWith("SmartPoolReserveExceeded()");
        });
        it("AND WHEN depositing 0.1 more to the sp, THEN it should not revert when trying to borrow 10.01 more", async () => {
          await fixedLenderDAI.deposit(parseUnits("0.1"), maria.address);
          await expect(
            fixedLenderDAI.borrowAtMaturity(
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
            await fixedLenderDAI.depositAtMaturity(
              futurePools(1)[0],
              parseUnits("10"),
              parseUnits("10"),
              maria.address,
            );
          });
          it("AND WHEN trying to borrow 20 more, THEN it should not revert", async () => {
            await expect(
              fixedLenderDAI.borrowAtMaturity(
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
              await fixedLenderDAI.borrowAtMaturity(
                futurePools(1)[0],
                parseUnits("10"),
                parseUnits("10"),
                maria.address,
                maria.address,
              );
              tx = fixedLenderDAI.withdrawAtMaturity(
                futurePools(1)[0],
                parseUnits("10"),
                parseUnits("10"),
                maria.address,
                maria.address,
              );
            });
            it("THEN the withdraw transaction should not revert", async () => {
              await expect(tx).to.not.be.reverted;
            });
            it("AND WHEN trying to borrow 0.01 more, THEN it should revert with SmartPoolReserveExceeded", async () => {
              await expect(
                fixedLenderDAI.borrowAtMaturity(
                  futurePools(1)[0],
                  parseUnits("0.01"),
                  parseUnits("0.01"),
                  maria.address,
                  maria.address,
                ),
              ).to.be.revertedWith("SmartPoolReserveExceeded()");
            });
            describe("AND GIVEN a repay of 5", () => {
              beforeEach(async () => {
                await fixedLenderDAI.repayAtMaturity(
                  futurePools(1)[0],
                  parseUnits("5"),
                  parseUnits("5"),
                  maria.address,
                );
              });
              it("WHEN trying to borrow 5 more, THEN it should not revert", async () => {
                await expect(
                  fixedLenderDAI.borrowAtMaturity(
                    futurePools(1)[0],
                    parseUnits("5"),
                    parseUnits("5"),
                    maria.address,
                    maria.address,
                  ),
                ).to.not.be.reverted;
              });
              it("AND WHEN trying to borrow 5.01 more, THEN it should revert with SmartPoolReserveExceeded", async () => {
                await expect(
                  fixedLenderDAI.borrowAtMaturity(
                    futurePools(1)[0],
                    parseUnits("5.01"),
                    parseUnits("5.01"),
                    maria.address,
                    maria.address,
                  ),
                ).to.be.revertedWith("SmartPoolReserveExceeded()");
              });
            });
          });
        });
      });
    });
  });
});
