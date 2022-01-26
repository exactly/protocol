import { expect } from "chai";
import { ethers } from "hardhat";
import { ExaTime } from "./exactlyUtils";
import { Contract, BigNumber } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv } from "./defaultEnv";

describe("ETHFixedLender - receive bare ETH instead of WETH", function () {
  let exactlyEnv: DefaultEnv;

  let weth: Contract;
  let eWeth: Contract;
  let ethFixedLender: Contract;
  let poolAccounting: Contract;

  let alice: SignerWithAddress;
  let owner: SignerWithAddress;
  const exaTime: ExaTime = new ExaTime();
  const nextPoolId: number = exaTime.nextPoolID();

  let snapshot: any;
  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    [owner, alice] = await ethers.getSigners();

    exactlyEnv = await DefaultEnv.create({});

    weth = exactlyEnv.getUnderlying("WETH");
    eWeth = exactlyEnv.getEToken("WETH");
    ethFixedLender = exactlyEnv.getFixedLender("WETH");
    poolAccounting = exactlyEnv.getPoolAccounting("WETH");
    exactlyEnv.switchWallet(alice);
  });

  describe("depositToMaturityPoolEth vs depositToMaturityPool", () => {
    describe("WHEN depositing 5 ETH (bare ETH, not WETH) to a maturity pool", () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.depositMPETH("WETH", nextPoolId, "5");
        await tx;
      });
      it("THEN a DepositToMaturityPool event is emitted", async () => {
        await expect(tx)
          .to.emit(ethFixedLender, "DepositToMaturityPool")
          .withArgs(
            alice.address,
            parseUnits("5"),
            parseUnits("0"), // commission, its zero with the mocked rate
            nextPoolId
          );
      });
      it("AND the ETHFixedLender contract has a balance of 5 WETH", async () => {
        expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
          parseUnits("5")
        );
      });
      it("AND the ETHFixedLender registers a supply of 5 WETH for the user", async () => {
        expect(
          await poolAccounting.mpUserSuppliedAmount(nextPoolId, alice.address)
        ).to.be.equal(parseUnits("5"));
      });
    });

    describe("GIVEN alice has some WETH", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(owner);
        await weth.transfer(alice.address, parseUnits("10"));
        exactlyEnv.switchWallet(alice);
      });
      describe("WHEN she deposits 5 WETH (ERC20) to a maturity pool", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.depositMP("WETH", nextPoolId, "5");
          await tx;
        });
        it("THEN a DepositToMaturityPool event is emitted", async () => {
          await expect(tx)
            .to.emit(ethFixedLender, "DepositToMaturityPool")
            .withArgs(
              alice.address,
              parseUnits("5"),
              parseUnits("0"), // commission, its zero with the mocked rate
              nextPoolId
            );
        });
        it("AND the ETHFixedLender contract has a balance of 5 WETH", async () => {
          expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
            parseUnits("5")
          );
        });
        it("AND the ETHFixedLender registers a supply of 5 WETH for the user", async () => {
          expect(
            await poolAccounting.mpUserSuppliedAmount(nextPoolId, alice.address)
          ).to.be.equal(parseUnits("5"));
        });
      });
    });
  });

  describe("depositToSmartPoolEth vs depositToSmartPool", () => {
    describe("WHEN alice deposits 5 ETH (bare ETH, not WETH) to a maturity pool", () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.depositSPETH("WETH", "5");
        await tx;
      });
      it("THEN a DepositToSmartPool event is emitted", async () => {
        await expect(tx)
          .to.emit(ethFixedLender, "DepositToSmartPool")
          .withArgs(alice.address, parseUnits("5"));
      });
      it("AND the ETHFixedLender contract has a balance of 5 WETH", async () => {
        expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
          parseUnits("5")
        );
      });
      it("AND alice has a balance of 5 eWETH", async () => {
        expect(await eWeth.balanceOf(alice.address)).to.be.equal(
          parseUnits("5")
        );
      });
    });

    describe("GIVEN alice has some WETH", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(owner);
        weth.transfer(alice.address, parseUnits("10"));
        exactlyEnv.switchWallet(alice);
      });
      describe("WHEN she deposits 5 WETH (ERC20) to the smart pool", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.depositSP("WETH", "5");
          await tx;
        });
        it("THEN a DepositToSmartPool event is emitted", async () => {
          await expect(tx)
            .to.emit(ethFixedLender, "DepositToSmartPool")
            .withArgs(alice.address, parseUnits("5"));
        });
        it("AND the ETHFixedLender contract has a balance of 5 WETH", async () => {
          expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
            parseUnits("5")
          );
        });
        it("AND alice has a balance of 5 eWETH", async () => {
          expect(await eWeth.balanceOf(alice.address)).to.be.equal(
            parseUnits("5")
          );
        });
      });
    });
  });

  describe("withdrawFromSmartPoolEth vs withdrawFromSmartPool", () => {
    describe("GIVEN alice already has a 5 ETH SP deposit", () => {
      beforeEach(async () => {
        weth.transfer(alice.address, parseUnits("10"));
        await exactlyEnv.depositSP("WETH", "5");
      });
      describe("WHEN withdrawing to 3 eWETH to ETH", () => {
        let tx: any;
        let aliceETHBalanceBefore: BigNumber;
        beforeEach(async () => {
          aliceETHBalanceBefore = await ethers.provider.getBalance(
            alice.address
          );
          tx = exactlyEnv.withdrawSPETH("WETH", "3");
          await tx;
        });
        it("THEN a WithdrawFromSmartPool event is emitted", async () => {
          await expect(tx)
            .to.emit(ethFixedLender, "WithdrawFromSmartPool")
            .withArgs(alice.address, parseUnits("3"));
        });
        it("AND the ETHFixedLender contract has a balance of 2 WETH", async () => {
          expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
            parseUnits("2")
          );
        });
        it("AND alice's ETH balance has increased by roughly 3", async () => {
          const newBalance = await ethers.provider.getBalance(alice.address);
          const balanceDiff = newBalance.sub(aliceETHBalanceBefore);
          expect(balanceDiff).to.be.gt(parseUnits("2.95"));
          expect(balanceDiff).to.be.lt(parseUnits("3"));
        });
      });
      describe("WHEN withdrawing 3 eWETH to WETH", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.withdrawSP("WETH", "3");
          await tx;
        });
        it("THEN a WithdrawFromSmartPool event is emitted", async () => {
          await expect(tx)
            .to.emit(ethFixedLender, "WithdrawFromSmartPool")
            .withArgs(alice.address, parseUnits("3"));
        });
        it("AND the ETHFixedLender contract has a balance of 2 WETH", async () => {
          expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
            parseUnits("2")
          );
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
        exactlyEnv.switchWallet(owner);
        weth.transfer(alice.address, parseUnits("10"));
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.depositMP("WETH", nextPoolId, "10");
        await exactlyEnv.moveInTime(nextPoolId);
      });
      describe("WHEN she withdraws to ETH", () => {
        let tx: any;
        let aliceETHBalanceBefore: BigNumber;
        beforeEach(async () => {
          aliceETHBalanceBefore = await ethers.provider.getBalance(
            alice.address
          );
          tx = exactlyEnv.withdrawMPETH("WETH", nextPoolId, "10");
          await tx;
        });
        it("THEN a WithdrawFromMaturityPool event is emmitted", async () => {
          await expect(tx)
            .to.emit(ethFixedLender, "WithdrawFromMaturityPool")
            .withArgs(alice.address, parseUnits("10"), nextPoolId);
        });
        it("AND alices ETH balance increases accordingly", async () => {
          const newBalance = await ethers.provider.getBalance(alice.address);
          const balanceDiff = newBalance.sub(aliceETHBalanceBefore);
          expect(balanceDiff).to.be.gt(parseUnits("9.95"));
          expect(balanceDiff).to.be.lt(parseUnits("10"));
        });
        it("AND the ETHFixedLender contracts WETH balance decreased accordingly", async () => {
          expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
            parseUnits("0")
          );
        });
      });
      describe("WHEN she withdraws to WETH", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.withdrawMP("WETH", nextPoolId, "10");
          await tx;
        });
        it("THEN a WithdrawFromMaturityPool event is emmitted", async () => {
          await expect(tx)
            .to.emit(ethFixedLender, "WithdrawFromMaturityPool")
            .withArgs(alice.address, parseUnits("10"), nextPoolId);
        });
        it("AND alices WETH balance increases accordingly", async () => {
          expect(await weth.balanceOf(alice.address)).to.equal(
            parseUnits("10")
          );
        });
        it("AND the ETHFixedLender contracts WETH balance decreased accordingly", async () => {
          expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
            parseUnits("0")
          );
        });
      });
    });
  });

  describe("borrowFromMaturityPoolEth vs borrowFromMaturityPool", () => {
    describe("GIVEN alice has some WETH collateral", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(owner);
        await weth.transfer(alice.address, parseUnits("60"));
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.depositSP("WETH", "60");
        await exactlyEnv.enterMarkets(["WETH"]);
      });
      describe("WHEN borrowing with ETH (native)", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.borrowMPETH("WETH", nextPoolId, "5");
          await tx;
        });
        it("THEN a BorrowFromMaturityPool event is emmitted", async () => {
          await expect(tx)
            .to.emit(
              exactlyEnv.getFixedLender("WETH"),
              "BorrowFromMaturityPool"
            )
            .withArgs(
              alice.address,
              parseUnits("5"),
              parseUnits("0"),
              nextPoolId
            );
        });
        it("AND a 5 DAI borrow is registered", async () => {
          expect(
            await exactlyEnv
              .getFixedLender("WETH")
              .getTotalMpBorrows(nextPoolId)
          ).to.equal(parseUnits("5"));
        });
        it("AND contract's state variable userMpBorrowed registers the maturity where the user borrowed from", async () => {
          expect(
            await exactlyEnv
              .getPoolAccounting("WETH")
              .userMpBorrowed(alice.address, 0)
          ).to.equal(nextPoolId);
        });
      });
      describe("WHEN borrowing with WETH (erc20)", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.borrowMP("WETH", nextPoolId, "5");
          await tx;
        });
        it("THEN a BorrowFromMaturityPool event is emmitted", async () => {
          await expect(tx)
            .to.emit(
              exactlyEnv.getFixedLender("WETH"),
              "BorrowFromMaturityPool"
            )
            .withArgs(
              alice.address,
              parseUnits("5"),
              parseUnits("0"),
              nextPoolId
            );
        });
        it("AND a 5 DAI borrow is registered", async () => {
          expect(
            await exactlyEnv
              .getFixedLender("WETH")
              .getTotalMpBorrows(nextPoolId)
          ).to.equal(parseUnits("5"));
        });
        it("AND contract's state variable userMpBorrowed registers the maturity where the user borrowed from", async () => {
          expect(
            await exactlyEnv
              .getPoolAccounting("WETH")
              .userMpBorrowed(alice.address, 0)
          ).to.equal(nextPoolId);
        });
      });

      describe("repayToMaturityPoolEth vs repayToMaturityPool", () => {
        describe("AND she borrows some WETH (erc20) AND maturity is reached", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("WETH", nextPoolId, "5");
            await exactlyEnv.moveInTime(nextPoolId);
          });

          describe("WHEN repaying in WETH (erc20)", () => {
            let tx: any;
            beforeEach(async () => {
              tx = exactlyEnv.repayMP("WETH", nextPoolId, "5");
              await tx;
            });
            it("THEN a RepayToMaturityPool event is emitted", async () => {
              await expect(tx)
                .to.emit(
                  exactlyEnv.getFixedLender("WETH"),
                  "RepayToMaturityPool"
                )
                .withArgs(
                  alice.address,
                  alice.address,
                  parseUnits("0"),
                  parseUnits("5"),
                  nextPoolId
                );
            });
            it("AND Alices debt is cleared", async () => {
              const [, amountOwed] = await exactlyEnv
                .getFixedLender("WETH")
                .getAccountSnapshot(alice.address, nextPoolId);
              expect(amountOwed).to.equal(parseUnits("0"));
            });
            it("AND WETH is returned to the contract", async () => {
              expect(await weth.balanceOf(alice.address)).to.equal(
                parseUnits("0")
              );
              expect(
                await weth.balanceOf(exactlyEnv.getFixedLender("WETH").address)
              ).to.equal(parseUnits("60"));
            });
          });
        });

        describe("AND she borrows some ETH (native) AND maturity is reached", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMPETH("WETH", nextPoolId, "5");
            await exactlyEnv.moveInTime(nextPoolId);
          });

          describe("WHEN repaying in WETH (native)", () => {
            let tx: any;
            let aliceETHBalanceBefore: BigNumber;
            beforeEach(async () => {
              aliceETHBalanceBefore = await ethers.provider.getBalance(
                alice.address
              );
              tx = exactlyEnv.repayMPETH("WETH", nextPoolId, "5");
              await tx;
            });
            it("THEN a RepayToMaturityPool event is emitted", async () => {
              await expect(tx)
                .to.emit(
                  exactlyEnv.getFixedLender("WETH"),
                  "RepayToMaturityPool"
                )
                .withArgs(
                  alice.address,
                  alice.address,
                  parseUnits("0"),
                  parseUnits("5"),
                  nextPoolId
                );
            });
            it("AND Alices debt is cleared", async () => {
              const [, amountOwed] = await exactlyEnv
                .getFixedLender("WETH")
                .getAccountSnapshot(alice.address, nextPoolId);
              expect(amountOwed).to.equal(parseUnits("0"));
            });
            it("AND ETH is returned to the contract", async () => {
              expect(
                await weth.balanceOf(exactlyEnv.getFixedLender("WETH").address)
              ).to.equal(parseUnits("60"));
              const newBalance = await ethers.provider.getBalance(
                alice.address
              );
              const balanceDiff = aliceETHBalanceBefore.sub(newBalance);
              expect(balanceDiff).to.be.lt(parseUnits("5.05"));
              expect(balanceDiff).to.be.gt(parseUnits("5"));
            });
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
