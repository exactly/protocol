import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  ProtocolError,
  errorGeneric,
  DefaultEnv,
  ExactlyEnv,
} from "./exactlyUtils";

describe("EToken", () => {
  let exactlyEnv: DefaultEnv;

  let bob: SignerWithAddress;
  let laura: SignerWithAddress;
  let eDAI: Contract;

  const mockedTokens = new Map([
    [
      "DAI",
      {
        decimals: 18,
        collateralRate: parseUnits("0.8"),
        usdPrice: parseUnits("1"),
      },
    ],
  ]);

  beforeEach(async () => {
    [bob, laura] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(mockedTokens);
    eDAI = exactlyEnv.getEToken("DAI");

    await eDAI.setExafin(bob.address); // We simulate that the address of user bob is the exafin contact
  });

  it("Mint should increase supply and balance of user", async () => {
    let amountToMint = parseUnits("100");
    await eDAI.mint(bob.address, amountToMint);
    let totalSupply = await eDAI.totalSupply();
    let userBalance = await eDAI.balanceOf(bob.address);

    expect(totalSupply).to.equal(amountToMint);
    expect(userBalance).to.equal(amountToMint);
  });

  it("Mint should correctly increase supply and balance of two different users in different calls", async () => {
    let amountToMint = parseUnits("1000");
    await eDAI.mint(bob.address, amountToMint);
    await eDAI.mint(laura.address, amountToMint);
    let totalSupply = await eDAI.totalSupply();
    let bobBalance = await eDAI.balanceOf(bob.address);
    let lauraBalance = await eDAI.balanceOf(laura.address);

    expect(bobBalance).to.equal(amountToMint);
    expect(lauraBalance).to.equal(amountToMint);
    expect(totalSupply).to.equal(parseUnits("2000"));
  });

  it("Mint should correctly increase balance of user if called several times", async () => {
    let amountToMint = parseUnits("100");
    await eDAI.mint(bob.address, amountToMint);
    await eDAI.mint(bob.address, amountToMint);
    let userBalance = await eDAI.balanceOf(bob.address);

    expect(userBalance).to.equal(parseUnits("200"));
  });

  it("Mint should emit event", async () => {
    let amountToMint = parseUnits("100");
    await expect(await eDAI.mint(bob.address, amountToMint)).to.emit(
      eDAI,
      "Transfer"
    );
  });

  it("BalanceOf should return zero if user never minted", async () => {
    let userBalance = await eDAI.balanceOf(bob.address);

    expect(userBalance).to.equal("0");
  });

  it("AccrueEarnings should increase user's balance if previously minted", async () => {
    let amountToMint = parseUnits("100");
    let amountToEarn = parseUnits("50");
    await eDAI.mint(bob.address, amountToMint);
    await eDAI.accrueEarnings(amountToEarn);
    let totalSupply = await eDAI.totalSupply();
    let userBalance = await eDAI.balanceOf(bob.address);

    expect(totalSupply).to.equal(parseUnits("150"));
    expect(userBalance).to.equal(parseUnits("150"));
  });

  it("AccrueEarnings should fail when total supply is zero", async () => {
    await expect(eDAI.accrueEarnings(parseUnits("100"))).to.be.reverted;
  });

  it("AccrueEarnings should not increase user's balance if minted later", async () => {
    let amountToEarn = parseUnits("50");
    let amountToMint = parseUnits("100");
    await eDAI.mint(laura.address, amountToMint);
    await eDAI.accrueEarnings(amountToEarn);
    await eDAI.mint(bob.address, amountToMint);
    let userBalance = await eDAI.balanceOf(bob.address);

    expect(userBalance).to.equal(amountToMint);
  });

  it("AccrueEarnings should emit event", async () => {
    let amountToEarn = parseUnits("100");
    await eDAI.mint(laura.address, amountToEarn);
    await expect(await eDAI.accrueEarnings(amountToEarn)).to.emit(
      eDAI,
      "EarningsAccrued"
    );
  });

  it("Burn should decrease supply and balance of user", async () => {
    let amountToMint = parseUnits("100");
    let amountToBurn = parseUnits("50");
    await eDAI.mint(bob.address, amountToMint);
    await eDAI.burn(bob.address, amountToBurn);
    let totalSupply = await eDAI.totalSupply();
    let userBalance = await eDAI.balanceOf(bob.address);

    expect(totalSupply).to.equal(parseUnits("50"));
    expect(userBalance).to.equal(parseUnits("50"));
  });

  it("Burn should emit event", async () => {
    let amountToMint = parseUnits("100");
    await expect(await eDAI.mint(bob.address, amountToMint)).to.emit(
      eDAI,
      "Transfer"
    );
  });

  it("SetExafin should fail when called from third parties", async () => {
    await expect(
      eDAI.connect(laura).setExafin(laura.address)
    ).to.be.revertedWith("AccessControl");
  });

  it("SetExafin should fail when Exafin address already set", async () => {
    await expect(eDAI.setExafin(laura.address)).to.be.revertedWith(
      errorGeneric(ProtocolError.EXAFIN_ALREADY_SETTED)
    );
  });

  describe("Modifiers", () => {
    it("Tries to invoke mint not being the Exafin", async () => {
      await expect(
        eDAI.connect(laura).mint(laura.address, "100")
      ).to.be.revertedWith(errorGeneric(ProtocolError.CALLER_MUST_BE_EXAFIN));
    });
    it("Tries to invoke accrueEarnings not being the Exafin", async () => {
      await expect(
        eDAI.connect(laura).accrueEarnings("100")
      ).to.be.revertedWith(errorGeneric(ProtocolError.CALLER_MUST_BE_EXAFIN));
    });
    it("Tries to invoke burn not being the Exafin", async () => {
      await expect(
        eDAI.connect(laura).burn(laura.address, "100")
      ).to.be.revertedWith(errorGeneric(ProtocolError.CALLER_MUST_BE_EXAFIN));
    });
  });
});
