import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { ExaTime } from "./exactlyUtils";
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
        weth.transfer(alice.address, parseUnits("10"));
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

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
