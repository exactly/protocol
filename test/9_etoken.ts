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
  let tito: SignerWithAddress;
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
    [bob, laura, tito] = await ethers.getSigners();

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

  it.only("withdraw and mints another user", async () => {
    let amountToMintBob = parseUnits("100");
    let amountToMintLaura = parseUnits("50");

    // bob 2/3 -- laura 1/3
    await eDAI.mint(bob.address, amountToMintBob);
    await eDAI.mint(laura.address, amountToMintLaura);
    await eDAI.accrueEarnings(parseUnits("60"));

    // bob 100 + 0.66_ * 60 = 140
    // laura 50 + 0.33_ * 60 = 70
    expect(await eDAI.totalSupply()).to.equal(parseUnits("210"));
    expect(await eDAI.balanceOf(bob.address)).to.equal(parseUnits("140"));

    // if we burn 140
    await eDAI.burn(bob.address, parseUnits("140"));

    // and laura is left out with 70
    expect(await eDAI.balanceOf(laura.address)).to.equal(parseUnits("70"));

    // someone else's joins with 70 (50 / 50 pool)
    await eDAI.mint(tito.address, parseUnits("70"));
    expect(await eDAI.balanceOf(tito.address)).to.equal(parseUnits("70"));
    expect(await eDAI.totalSupply()).to.equal(parseUnits("140"));

    // ... and we deposit some more earnings (it should be 50 and 50)
    await eDAI.accrueEarnings(parseUnits("100"));

    // then 70 each + 50 each = 120 (and total supply 240)
    expect(await eDAI.totalSupply()).to.equal(parseUnits("240"));
    expect(await eDAI.balanceOf(laura.address)).to.equal(parseUnits("120"));

    // then burns 80 from laura
    await eDAI.burn(laura.address, parseUnits("80"));
    expect(await eDAI.balanceOf(laura.address)).to.equal(parseUnits("40"));
    // TODO: Rounding Errors
    expect(await eDAI.balanceOf(tito.address)).to.closeTo(
      parseUnits("120"),
      10
    );
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
