import { expect } from "chai";
import { ethers } from "hardhat"
import { Contract, BigNumber } from "ethers"

Error.stackTraceLimit = Infinity;

describe("Exafin", function() {

    let exafin: Contract
    let underlyingToken: Contract

    let ownerAddress: string
    let userAddress: string
  
    beforeEach(async () => {
        const [owner, user] = await ethers.getSigners()
        ownerAddress = await owner.getAddress()
        userAddress = await user.getAddress()

        const SomeToken = await ethers.getContractFactory("SomeToken")
        underlyingToken = await SomeToken.deploy("Fake Stable", "FSTA", "100000000000000000000000000000000")
        await underlyingToken.deployed()

        const Exafin = await ethers.getContractFactory("Exafin");
        exafin = await Exafin.deploy(underlyingToken.address)
        await exafin.deployed();
    })

    it('it allows to lend to a pool', async () => {
        const now = Math.floor(Date.now() / 1000)
        const underlyingAmount = 100
        await underlyingToken.approve(exafin.address, underlyingAmount)
        await exafin.lend(ownerAddress, underlyingAmount, now)
        expect (await underlyingToken.balanceOf(exafin.address)).to.equal(underlyingAmount)
    })

    it('it allows to borrow from a pool', async () => {
        const now = Math.floor(Date.now() / 1000)
        const underlyingAmount = 100
        // Send from owner to protocol
        await underlyingToken.approve(exafin.address, underlyingAmount)
        await exafin.lend(ownerAddress, underlyingAmount, now)

        // Borrow from userAddress wallet
        await exafin.borrow(userAddress, underlyingAmount, now)
        expect (await underlyingToken.balanceOf(userAddress)).to.equal(underlyingAmount)
    })

});
