import { expect } from "chai";
import { ethers } from "hardhat";
import { Signer } from "ethers";
import { MockProvider } from 'ethereum-waffle';
import { Contract } from "ethers"

describe("Lender", function() {
  let lender: Contract
  let dai: Contract
  let ownerAddress: string
  let initialFunds = 100

  beforeEach(async () => {
    const [owner] = await ethers.getSigners();
    ownerAddress = await owner.getAddress();
    const Dai = await ethers.getContractFactory("Dai");
    dai = await Dai.deploy();

    const Lender = await ethers.getContractFactory("Lender");
    lender = await Lender.deploy(dai.address);

    await dai.faucet(lender.address, initialFunds);
    await dai.faucet(ownerAddress, initialFunds);

    console.log("Lender deployed to:", lender.address);
    console.log("Dai deployed to:", dai.address);
  })

  it("Should increase balance when pooling", async function() {
    await lender.pool(1, { value: 50 });
    expect(await lender.balance()).to.equal(1);
    await lender.pool(1, { value: 50 });
    expect(await lender.balance()).to.equal(2);
    expect(await dai.balanceOf(lender.address)).to.equal(initialFunds + 2);
    expect(await dai.balanceOf(ownerAddress)).to.equal(initialFunds - 2);
  });

  it("Should decrease to 0", async function() {
    await lender.pool(1, { value: 50 });
    expect(await lender.balance()).to.equal(1);
    expect(await lender.withdraw(1));
    expect(await lender.balance()).to.equal(0);
    expect(await dai.balanceOf(ownerAddress)).to.equal(initialFunds);
    expect(await dai.balanceOf(lender.address)).to.equal(initialFunds);
  });

  it("Should revert because not enough funds", async function() {
    await lender.pool(1, { value: 50 });
    expect(await lender.balance()).to.equal(1);
    expect(lender.withdraw(2)).to.be.reverted;
    expect(await dai.balanceOf(ownerAddress)).to.equal(initialFunds)
    expect(await dai.balanceOf(lender.address)).to.equal(initialFunds);
  });
});
