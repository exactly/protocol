import { expect } from "chai";
import { ethers } from "hardhat"
import { Contract, BigNumber } from "ethers"
import { parseBorrowEvent, parseLendEvent } from "./exactlyUtils"

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

        const totalSupply = ethers.utils.parseUnits("100000000000", 18);
        const SomeToken = await ethers.getContractFactory("SomeToken")
        underlyingToken = await SomeToken.deploy("Fake Stable", "FSTA", totalSupply.toString())
        await underlyingToken.deployed()

        const Exafin = await ethers.getContractFactory("Exafin");
        exafin = await Exafin.deploy(underlyingToken.address, "FSTA")
        await exafin.deployed();
    })

    it('it allows to give money to a pool', async () => {
        const now = Math.floor(Date.now() / 1000)
        const underlyingAmount = 100
        await underlyingToken.approve(exafin.address, underlyingAmount)

        ethers.getDefaultProvider().pollingInterval = 2000

        let tx = await exafin.borrowFrom(ownerAddress, underlyingAmount, now)
        let event = await parseBorrowEvent(tx)

        expect(event.to).to.equal(ownerAddress)
        expect(event.amount).to.equal(underlyingAmount)
        expect(event.maturityDate).to.equal(now - (now % (86400 * 30)) + 86400 * 30)

        expect(await underlyingToken.balanceOf(exafin.address)).to.equal(underlyingAmount)
    })

    it('it allows to get money from a pool', async () => {
        const now = Math.floor(Date.now() / 1000)
        const borrowAmount = 100
        const lendAmount = 50

        // borrow from owneraddress wallet 
        await underlyingToken.approve(exafin.address, borrowAmount)
        await exafin.borrowFrom(ownerAddress, borrowAmount, now)

        let tx = await exafin.lendTo(userAddress, lendAmount, now)
        let event = await parseLendEvent(tx) 

        expect(event.from).to.equal(userAddress)
        expect(event.amount).to.equal(lendAmount)
        expect(event.maturityDate).to.equal(now - (now % (86400 * 30)) + 86400 * 30)
        expect(await underlyingToken.balanceOf(userAddress)).to.equal(lendAmount)
    })

});
