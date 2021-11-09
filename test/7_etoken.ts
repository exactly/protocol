import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("EToken", () => {
  let bob: SignerWithAddress;
  let laura: SignerWithAddress;
  let eToken: Contract;

  beforeEach(async () => {
    [bob, laura] = await ethers.getSigners();

    const EToken = await ethers.getContractFactory("EToken", {});
    eToken = await EToken.deploy();
    await eToken.deployed();
  });

  it("Mint should increase supply and balance of user", async () => {
    let amountToMint = parseUnits("100");
    await eToken.mint(bob.address, amountToMint);
    let totalSupply = await eToken.totalSupply();
    let userBalance = await eToken.balanceOf(bob.address);

    expect(totalSupply).to.equal(amountToMint);
    expect(userBalance).to.equal(amountToMint);
  });

  it("Mint should correctly increase balance of user if called several times", async () => {
    let amountToMint = parseUnits("100");
    await eToken.mint(bob.address, amountToMint);
    await eToken.increaseLiquidity(parseUnits("100"));
    await eToken.mint(bob.address, amountToMint);
    let userBalance = await eToken.balanceOf(bob.address);

    expect(userBalance).to.equal(parseUnits("300"));
  });

  it("BalanceOf should return zero if user never minted", async () => {
    let userBalance = await eToken.balanceOf(bob.address);

    expect(userBalance).to.equal("0");
  });

  it("IncreaseLiquidity should increase user's balance if previously minted", async () => {
    let amountToMint = parseUnits("100");
    let amountToEarn = parseUnits("50");
    await eToken.mint(bob.address, amountToMint);
    await eToken.increaseLiquidity(amountToEarn);
    let totalSupply = await eToken.totalSupply();
    let userBalance = await eToken.balanceOf(bob.address);

    expect(totalSupply).to.equal(parseUnits("150"));
    expect(userBalance).to.equal(parseUnits("150"));
  });

  it("IncreaseLiquidity should fail when total supply is zero", async () => {
    await expect(eToken.increaseLiquidity(parseUnits("100"))).to.be.reverted;
  });

  it("IncreaseLiquidity should not increase user's balance if minted later", async () => {
    let amountToEarn = parseUnits("50");
    let amountToMint = parseUnits("100");
    await eToken.mint(laura.address, amountToMint);
    await eToken.increaseLiquidity(amountToEarn);
    await eToken.mint(bob.address, amountToMint);
    let userBalance = await eToken.balanceOf(bob.address);

    expect(userBalance).to.equal(amountToMint);
  });

  it("Burn should decrease supply and balance of user", async () => {
    let amountToMint = parseUnits("100");
    let amountToBurn = parseUnits("50");
    await eToken.mint(bob.address, amountToMint);
    await eToken.burn(bob.address, amountToBurn);
    let totalSupply = await eToken.totalSupply();
    let userBalance = await eToken.balanceOf(bob.address);

    expect(totalSupply).to.equal(parseUnits("50"));
    expect(userBalance).to.equal(parseUnits("50"));
  });
});
