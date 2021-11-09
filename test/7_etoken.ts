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

  it("Mint should correctly increase supply and balance of two different users in different calls", async () => {
    let amountToMint = parseUnits("1000");
    await eToken.mint(bob.address, amountToMint);
    await eToken.mint(laura.address, amountToMint);
    let totalSupply = await eToken.totalSupply();
    let bobBalance = await eToken.balanceOf(bob.address);
    let lauraBalance = await eToken.balanceOf(laura.address);

    expect(bobBalance).to.equal(amountToMint);
    expect(lauraBalance).to.equal(amountToMint);
    expect(totalSupply).to.equal("2000");
  });

  it("Mint should correctly increase balance of user if called several times", async () => {
    let amountToMint = parseUnits("100");
    await eToken.mint(bob.address, amountToMint);
    await eToken.mint(bob.address, amountToMint);
    let userBalance = await eToken.balanceOf(bob.address);

    expect(userBalance).to.equal(parseUnits("200"));
  });

  it("BalanceOf should return zero if user never minted", async () => {
    let userBalance = await eToken.balanceOf(bob.address);

    expect(userBalance).to.equal("0");
  });

  it("AccrueEarnings should increase user's balance if previously minted", async () => {
    let amountToMint = parseUnits("100");
    let amountToEarn = parseUnits("50");
    await eToken.mint(bob.address, amountToMint);
    await eToken.accrueEarnings(amountToEarn);
    let totalSupply = await eToken.totalSupply();
    let userBalance = await eToken.balanceOf(bob.address);

    expect(totalSupply).to.equal(parseUnits("150"));
    expect(userBalance).to.equal(parseUnits("150"));
  });

  it("AccrueEarnings should fail when total supply is zero", async () => {
    await expect(eToken.accrueEarnings(parseUnits("100"))).to.be.reverted;
  });

  it("AccrueEarnings should not increase user's balance if minted later", async () => {
    let amountToEarn = parseUnits("50");
    let amountToMint = parseUnits("100");
    await eToken.mint(laura.address, amountToMint);
    await eToken.accrueEarnings(amountToEarn);
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
