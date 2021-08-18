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

    it('it allows to give money to a pool', async () => {
        const now = Math.floor(Date.now() / 1000)
        const underlyingAmount = 100
        await underlyingToken.approve(exafin.address, underlyingAmount)
        await exafin.borrow(ownerAddress, underlyingAmount, now)
        expect (await underlyingToken.balanceOf(exafin.address)).to.equal(underlyingAmount)
    })

    it('it allows to get money from a pool', async () => {
        const now = Math.floor(Date.now() / 1000)
        const underlyingAmount = 100
        // borrow from owneraddress wallet 
        await underlyingToken.approve(exafin.address, underlyingAmount)
        await exafin.borrow(ownerAddress, underlyingAmount, now)

        // Lend to userAddress wallet
        await exafin.lend(userAddress, underlyingAmount, now)
        expect (await underlyingToken.balanceOf(userAddress)).to.equal(underlyingAmount)
    })

});
