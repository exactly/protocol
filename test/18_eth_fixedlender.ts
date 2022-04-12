import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { BigNumber, ContractTransaction } from "ethers";
import type { Auditor, FixedLender, FixedLenderETHRouter, MockInterestRateModel, WETH } from "../types";
import { decodeMaturities } from "./exactlyUtils";
import timelockExecute from "./utils/timelockExecute";
import futurePools from "./utils/futurePools";

const {
  utils: { parseUnits },
  getUnnamedSigners,
  getNamedSigner,
  getContract,
  provider,
} = ethers;

describe("ETHFixedLender - receive bare ETH instead of WETH", function () {
  let irm: MockInterestRateModel;
  let weth: WETH;
  let auditor: Auditor;
  let routerETH: FixedLenderETHRouter;
  let fixedLenderWETH: FixedLender;

  let alice: SignerWithAddress;

  before(async () => {
    [alice] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture(["Markets"]);

    weth = await getContract<WETH>("WETH", alice);
    weth = await getContract<WETH>("WETH", alice);
    auditor = await getContract<Auditor>("Auditor", alice);
    routerETH = await getContract<FixedLenderETHRouter>("FixedLenderETHRouter", alice);
    fixedLenderWETH = await getContract<FixedLender>("FixedLenderWETH", alice);

    const owner = await getNamedSigner("multisig");
    await deployments.deploy("MockInterestRateModel", { args: [0], from: owner.address });
    irm = await getContract<MockInterestRateModel>("MockInterestRateModel", alice);
    await timelockExecute(owner, fixedLenderWETH, "setInterestRateModel", [irm.address]);
    // await timelockExecute(owner, fixedLenderWETH, "setPenaltyRate", [0]);

    await weth.approve(fixedLenderWETH.address, parseUnits("100"));
    await fixedLenderWETH.approve(routerETH.address, parseUnits("100"));
  });

  describe("depositToMaturityPoolETH vs depositToMaturityPool", () => {
    describe("WHEN depositing 5 ETH (bare ETH, not WETH) to a maturity pool", () => {
      let tx: ContractTransaction;
      beforeEach(async () => {
        tx = await routerETH.depositAtMaturityETH(futurePools(1)[0], parseUnits("5"), { value: parseUnits("5") });
      });
      it("THEN a DepositAtMaturity event is emitted", async () => {
        await expect(tx)
          .to.emit(fixedLenderWETH, "DepositAtMaturity")
          .withArgs(futurePools(1)[0], routerETH.address, alice.address, parseUnits("5"), parseUnits("0"));
      });
      it("AND the ETHFixedLender contract has a balance of 5 WETH", async () => {
        expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(parseUnits("5"));
      });
      it("AND the ETHFixedLender registers a supply of 5 WETH for the user", async () => {
        const position = await fixedLenderWETH.mpUserSuppliedAmount(futurePools(1)[0], alice.address);
        expect(position[0]).to.be.equal(parseUnits("5"));
      });
      it("AND contract's state variable userMpSupplied registers the maturity where the user deposited to", async () => {
        const maturities = await fixedLenderWETH.userMpSupplied(alice.address);
        expect(decodeMaturities(maturities)).contains(futurePools(1)[0].toNumber());
      });
    });

    describe("GIVEN alice has some WETH", () => {
      beforeEach(async () => {
        await weth.deposit({ value: parseUnits("10") });
      });
      describe("WHEN she deposits 5 WETH (ERC20) to a maturity pool", () => {
        let tx: ContractTransaction;
        beforeEach(async () => {
          tx = await fixedLenderWETH.depositAtMaturity(
            futurePools(1)[0],
            parseUnits("5"),
            parseUnits("5"),
            alice.address,
          );
        });
        it("THEN a DepositToMaturityPool event is emitted", async () => {
          await expect(tx)
            .to.emit(fixedLenderWETH, "DepositAtMaturity")
            .withArgs(futurePools(1)[0], alice.address, alice.address, parseUnits("5"), parseUnits("0"));
        });
        it("AND the ETHFixedLender contract has a balance of 5 WETH", async () => {
          expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(parseUnits("5"));
        });
        it("AND the ETHFixedLender registers a supply of 5 WETH for the user", async () => {
          const position = await fixedLenderWETH.mpUserSuppliedAmount(futurePools(1)[0], alice.address);
          expect(position[0]).to.be.equal(parseUnits("5"));
        });
        it("AND contract's state variable userMpSupplied registers the maturity where the user deposited to", async () => {
          const maturities = await fixedLenderWETH.userMpSupplied(alice.address);
          expect(decodeMaturities(maturities)).contains(futurePools(1)[0].toNumber());
        });
      });
    });
  });

  describe("depositToSmartPoolETH vs depositToSmartPool", () => {
    describe("WHEN alice deposits 5 ETH (bare ETH, not WETH) to a maturity pool", () => {
      let tx: ContractTransaction;
      beforeEach(async () => {
        tx = await routerETH.depositETH({ value: parseUnits("5") });
      });
      it("THEN a Deposit event is emitted", async () => {
        await expect(tx)
          .to.emit(fixedLenderWETH, "Deposit")
          .withArgs(routerETH.address, alice.address, parseUnits("5"), parseUnits("5"));
      });
      it("AND the ETHFixedLender contract has a balance of 5 WETH", async () => {
        expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(parseUnits("5"));
      });
      it("AND alice has a balance of 5 eWETH", async () => {
        expect(await fixedLenderWETH.balanceOf(alice.address)).to.be.equal(parseUnits("5"));
      });
    });

    describe("GIVEN alice has some WETH", () => {
      beforeEach(async () => {
        await weth.deposit({ value: parseUnits("10") });
      });
      describe("WHEN she deposits 5 WETH (ERC20) to the smart pool", () => {
        let tx: ContractTransaction;
        beforeEach(async () => {
          tx = await fixedLenderWETH.deposit(parseUnits("5"), alice.address);
        });
        it("THEN a Deposit event is emitted", async () => {
          await expect(tx)
            .to.emit(fixedLenderWETH, "Deposit")
            .withArgs(alice.address, alice.address, parseUnits("5"), parseUnits("5"));
        });
        it("AND the ETHFixedLender contract has a balance of 5 WETH", async () => {
          expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(parseUnits("5"));
        });
        it("AND alice has a balance of 5 eWETH", async () => {
          expect(await fixedLenderWETH.balanceOf(alice.address)).to.be.equal(parseUnits("5"));
        });
      });
    });
  });

  describe("withdrawFromSmartPoolETH vs withdrawFromSmartPool", () => {
    describe("GIVEN alice already has a 5 ETH SP deposit", () => {
      beforeEach(async () => {
        await weth.deposit({ value: parseUnits("10") });
        await fixedLenderWETH.deposit(parseUnits("5"), alice.address);
      });
      describe("WHEN withdrawing to 3 eWETH to ETH", () => {
        let tx: ContractTransaction;
        let aliceETHBalanceBefore: BigNumber;
        beforeEach(async () => {
          aliceETHBalanceBefore = await provider.getBalance(alice.address);
          tx = await routerETH.withdrawETH(parseUnits("3"));
        });
        it("THEN a Withdraw event is emitted", async () => {
          await expect(tx)
            .to.emit(fixedLenderWETH, "Withdraw")
            .withArgs(routerETH.address, routerETH.address, alice.address, parseUnits("3"), parseUnits("3"));
        });
        it("AND the ETHFixedLender contract has a balance of 2 WETH", async () => {
          expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(parseUnits("2"));
        });
        it("AND alice's ETH balance has increased by roughly 3", async () => {
          const newBalance = await provider.getBalance(alice.address);
          const balanceDiff = newBalance.sub(aliceETHBalanceBefore);
          expect(balanceDiff).to.be.gt(parseUnits("2.95"));
          expect(balanceDiff).to.be.lt(parseUnits("3"));
        });
      });
      describe("WHEN withdrawing 3 eWETH to WETH", () => {
        let tx: ContractTransaction;
        beforeEach(async () => {
          tx = await fixedLenderWETH.withdraw(parseUnits("3"), alice.address, alice.address);
        });
        it("THEN a Withdraw event is emitted", async () => {
          await expect(tx)
            .to.emit(fixedLenderWETH, "Withdraw")
            .withArgs(alice.address, alice.address, alice.address, parseUnits("3"), parseUnits("3"));
        });
        it("AND the ETHFixedLender contract has a balance of 2 WETH", async () => {
          expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(parseUnits("2"));
        });
        it("AND alice recovers her 2 ETH", async () => {
          expect(await weth.balanceOf(alice.address)).to.equal(parseUnits("8"));
        });
      });
    });
  });

  describe("withdrawFromMaturityPoolETH vs withdrawFromMaturityPool", () => {
    describe("GIVEN alice has a deposit to ETH maturity AND maturity is reached", () => {
      beforeEach(async () => {
        await weth.deposit({ value: parseUnits("10") });
        await fixedLenderWETH.depositAtMaturity(futurePools(1)[0], parseUnits("10"), parseUnits("10"), alice.address);
        await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber()]);
      });
      describe("WHEN she withdraws to ETH", () => {
        let tx: ContractTransaction;
        let aliceETHBalanceBefore: BigNumber;
        beforeEach(async () => {
          aliceETHBalanceBefore = await provider.getBalance(alice.address);
          tx = await routerETH.withdrawAtMaturityETH(futurePools(1)[0], parseUnits("10"), 0);
        });
        it("THEN a WithdrawFromMaturityPool event is emmitted", async () => {
          await expect(tx)
            .to.emit(fixedLenderWETH, "WithdrawAtMaturity")
            .withArgs(
              futurePools(1)[0],
              routerETH.address,
              routerETH.address,
              alice.address,
              parseUnits("10"),
              parseUnits("10"),
            );
        });
        it("AND alices ETH balance increases accordingly", async () => {
          const newBalance = await provider.getBalance(alice.address);
          const balanceDiff = newBalance.sub(aliceETHBalanceBefore);
          expect(balanceDiff).to.be.gt(parseUnits("9.95"));
          expect(balanceDiff).to.be.lt(parseUnits("10"));
        });
        it("AND the ETHFixedLender contracts WETH balance decreased accordingly", async () => {
          expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(parseUnits("0"));
        });
        it("AND contract's state variable userMpSupplied registers the maturity where the user deposited to", async () => {
          const maturities = await fixedLenderWETH.userMpSupplied(alice.address);
          expect(decodeMaturities(maturities).length).equal(0);
        });
      });
      describe("WHEN she withdraws to WETH", () => {
        let tx: ContractTransaction;
        beforeEach(async () => {
          tx = await fixedLenderWETH.withdrawAtMaturity(
            futurePools(1)[0],
            parseUnits("10"),
            0,
            alice.address,
            alice.address,
          );
        });
        it("THEN a WithdrawFromMaturityPool event is emmitted", async () => {
          await expect(tx)
            .to.emit(fixedLenderWETH, "WithdrawAtMaturity")
            .withArgs(
              futurePools(1)[0],
              alice.address,
              alice.address,
              alice.address,
              parseUnits("10"),
              parseUnits("10"),
            );
        });
        it("AND alices WETH balance increases accordingly", async () => {
          expect(await weth.balanceOf(alice.address)).to.equal(parseUnits("10"));
        });
        it("AND the ETHFixedLender contracts WETH balance decreased accordingly", async () => {
          expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(parseUnits("0"));
        });
      });
    });
  });

  describe("borrowFromMaturityPoolETH vs borrowFromMaturityPool", () => {
    describe("GIVEN alice has some WETH collateral", () => {
      beforeEach(async () => {
        await weth.deposit({ value: parseUnits("60") });
        await fixedLenderWETH.deposit(parseUnits("60"), alice.address);
        await auditor.enterMarkets([fixedLenderWETH.address]);
      });
      describe("WHEN borrowing with ETH (native)", () => {
        let tx: ContractTransaction;
        beforeEach(async () => {
          tx = await routerETH.borrowAtMaturityETH(futurePools(1)[0], parseUnits("5"), parseUnits("6"));
        });
        it("THEN a BorrowFromMaturityPool event is emitted", async () => {
          await expect(tx)
            .to.emit(fixedLenderWETH, "BorrowAtMaturity")
            .withArgs(futurePools(1)[0], routerETH.address, routerETH.address, alice.address, parseUnits("5"), 0);
        });
        it("AND a 5 WETH borrow is registered", async () => {
          expect((await fixedLenderWETH.maturityPools(futurePools(1)[0]))[0]).to.equal(parseUnits("5"));
        });
        it("AND contract's state variable userMpBorrowed registers the maturity where the user borrowed from", async () => {
          const maturities = await fixedLenderWETH.userMpBorrowed(alice.address);
          expect(decodeMaturities(maturities)).contains(futurePools(1)[0].toNumber());
        });
      });
      describe("WHEN borrowing with WETH (erc20)", () => {
        let tx: ContractTransaction;
        beforeEach(async () => {
          tx = await fixedLenderWETH.borrowAtMaturity(
            futurePools(1)[0],
            parseUnits("5"),
            parseUnits("6"),
            alice.address,
            alice.address,
          );
        });
        it("THEN a BorrowFromMaturityPool event is emitted", async () => {
          await expect(tx)
            .to.emit(fixedLenderWETH, "BorrowAtMaturity")
            .withArgs(futurePools(1)[0], alice.address, alice.address, alice.address, parseUnits("5"), 0);
        });
        it("AND a 5 WETH borrow is registered", async () => {
          expect((await fixedLenderWETH.maturityPools(futurePools(1)[0]))[0]).to.equal(parseUnits("5"));
        });
        it("AND contract's state variable userMpBorrowed registers the maturity where the user borrowed from", async () => {
          const maturities = await fixedLenderWETH.userMpBorrowed(alice.address);
          expect(decodeMaturities(maturities)).contains(futurePools(1)[0].toNumber());
        });
      });

      describe("repayToMaturityPoolETH vs repayToMaturityPool", () => {
        describe("AND she borrows some WETH (erc20) AND maturity is reached", () => {
          beforeEach(async () => {
            await fixedLenderWETH.borrowAtMaturity(
              futurePools(1)[0],
              parseUnits("5"),
              parseUnits("6"),
              alice.address,
              alice.address,
            );
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber()]);
          });

          describe("WHEN repaying in WETH (erc20)", () => {
            let tx: ContractTransaction;
            beforeEach(async () => {
              tx = await fixedLenderWETH.repayAtMaturity(
                futurePools(1)[0],
                parseUnits("5"),
                parseUnits("6"),
                alice.address,
              );
            });
            it("THEN a RepayToMaturityPool event is emitted", async () => {
              await expect(tx)
                .to.emit(fixedLenderWETH, "RepayAtMaturity")
                .withArgs(futurePools(1)[0], alice.address, alice.address, parseUnits("5"), parseUnits("5"));
            });
            it("AND Alice's debt is cleared", async () => {
              const [, amountOwed] = await fixedLenderWETH.getAccountSnapshot(alice.address, futurePools(1)[0]);
              expect(amountOwed).to.equal(parseUnits("0"));
            });
            it("AND WETH is returned to the contract", async () => {
              expect(await weth.balanceOf(alice.address)).to.equal(parseUnits("0"));
              expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(parseUnits("60"));
            });
          });
        });

        describe("AND she borrows some ETH (native) AND maturity is reached", () => {
          beforeEach(async () => {
            await routerETH.borrowAtMaturityETH(futurePools(1)[0], parseUnits("5"), parseUnits("6"));
            await provider.send("evm_setNextBlockTimestamp", [futurePools(1)[0].toNumber()]);
          });

          describe("WHEN repaying in ETH (native)", () => {
            let tx: ContractTransaction;
            let aliceETHBalanceBefore: BigNumber;
            beforeEach(async () => {
              aliceETHBalanceBefore = await provider.getBalance(alice.address);
              tx = await routerETH.repayAtMaturityETH(futurePools(1)[0], parseUnits("5"), { value: parseUnits("6") });
            });
            it("THEN a RepayToMaturityPool event is emitted", async () => {
              await expect(tx)
                .to.emit(fixedLenderWETH, "RepayAtMaturity")
                .withArgs(futurePools(1)[0], routerETH.address, alice.address, parseUnits("5"), parseUnits("5"));
            });
            it("AND Alice's debt is cleared", async () => {
              const [, amountOwed] = await fixedLenderWETH.getAccountSnapshot(alice.address, futurePools(1)[0]);
              expect(amountOwed).to.equal(parseUnits("0"));
            });
            it("AND ETH is returned to the contract", async () => {
              expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(parseUnits("60"));
              const newBalance = await provider.getBalance(alice.address);
              const balanceDiff = aliceETHBalanceBefore.sub(newBalance);
              expect(balanceDiff).to.be.lt(parseUnits("5.05"));
              expect(balanceDiff).to.be.gt(parseUnits("5"));
            });
          });
          describe("WHEN repaying more than debt amount in ETH (native)", () => {
            let aliceETHBalanceBefore: BigNumber;
            beforeEach(async () => {
              aliceETHBalanceBefore = await provider.getBalance(alice.address);
              await routerETH.repayAtMaturityETH(futurePools(1)[0], parseUnits("10"), { value: parseUnits("10") });
            });
            it("AND Alice's debt is cleared", async () => {
              const [, amountOwed] = await fixedLenderWETH.getAccountSnapshot(alice.address, futurePools(1)[0]);
              expect(amountOwed).to.equal(parseUnits("0"));
            });
            it("AND ETH is returned to the contract", async () => {
              expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(parseUnits("60"));
              const newBalance = await provider.getBalance(alice.address);
              const balanceDiff = aliceETHBalanceBefore.sub(newBalance);
              expect(balanceDiff).to.be.lt(parseUnits("5.05"));
              expect(balanceDiff).to.be.gt(parseUnits("5"));
            });
          });
        });
      });
    });
  });

  describe("slippage control", () => {
    let tx: Promise<ContractTransaction>;
    beforeEach(async () => {
      await irm.setBorrowRate(parseUnits("0.05"));
    });
    describe("WHEN trying to deposit a high rate amount expected", () => {
      beforeEach(async () => {
        tx = routerETH.depositAtMaturityETH(futurePools(1)[0], parseUnits("10"), { value: parseUnits("5") });
      });
      it("THEN the tx should revert with TooMuchSlippage", async () => {
        await expect(tx).to.be.revertedWith("TooMuchSlippage()");
      });
    });
    describe("WHEN trying to borrow with a low rate amount expected", () => {
      beforeEach(async () => {
        await weth.deposit({ value: parseUnits("60") });
        await fixedLenderWETH.deposit(parseUnits("60"), alice.address);
        await auditor.enterMarkets([fixedLenderWETH.address]);
        tx = routerETH.borrowAtMaturityETH(futurePools(1)[0], parseUnits("5"), parseUnits("5"));
      });
      it("THEN the tx should revert with TooMuchSlippage", async () => {
        await expect(tx).to.be.revertedWith("TooMuchSlippage()");
      });
    });
    describe("WHEN trying to withdraw with a high rate amount expected", () => {
      beforeEach(async () => {
        await routerETH.depositAtMaturityETH(futurePools(1)[0], parseUnits("5"), { value: parseUnits("5") });
        tx = routerETH.withdrawAtMaturityETH(futurePools(1)[0], parseUnits("5"), parseUnits("10"));
      });
      it("THEN the tx should revert with TooMuchSlippage", async () => {
        await expect(tx).to.be.revertedWith("TooMuchSlippage()");
      });
    });
    describe("WHEN trying to repay with a low rate amount expected", () => {
      beforeEach(async () => {
        await weth.deposit({ value: parseUnits("60") });
        await fixedLenderWETH.deposit(parseUnits("60"), alice.address);
        await auditor.enterMarkets([fixedLenderWETH.address]);
        await routerETH.borrowAtMaturityETH(futurePools(1)[0], parseUnits("5"), parseUnits("10"));
        tx = routerETH.repayAtMaturityETH(futurePools(1)[0], parseUnits("5"), { value: parseUnits("4") });
      });
      it("THEN the tx should revert with TooMuchSlippage", async () => {
        await expect(tx).to.be.revertedWith("TooMuchSlippage()");
      });
    });
  });
});
