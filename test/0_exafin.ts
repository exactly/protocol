import { expect } from "chai";
import { ethers } from "hardhat"
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers"
import { parseSupplyEvent } from "./exactlyUtils"
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

Error.stackTraceLimit = Infinity;

describe("Exafin", function() {

    let exafin: Contract
    let underlyingToken: Contract

    let user: SignerWithAddress
    let owner: SignerWithAddress
  
    beforeEach(async () => {
        [owner, user] = await ethers.getSigners()

        const totalSupply = parseUnits("100000000000", 18);
        const SomeToken = await ethers.getContractFactory("SomeToken")
        underlyingToken = await SomeToken.deploy("Fake Stable", "FSTA", totalSupply.toString())
        await underlyingToken.deployed()

        underlyingToken.transfer(user.address, parseUnits("100"))

        const Exafin = await ethers.getContractFactory("Exafin");
        exafin = await Exafin.deploy(underlyingToken.address, "FSTA")
        await exafin.deployed();
    })

    it('it allows to give money to a pool', async () => {
        const now = Math.floor(Date.now() / 1000)
        const underlyingAmount = 100
        await underlyingToken.approve(exafin.address, underlyingAmount)

        let tx = await exafin.supply(owner.address, underlyingAmount, now)
        let event = await parseSupplyEvent(tx)

        expect(event.from).to.equal(owner.address)
        expect(event.amount).to.equal(underlyingAmount)
        expect(event.maturityDate).to.equal(now - (now % (86400 * 30)) + 86400 * 30)

        expect(await underlyingToken.balanceOf(exafin.address)).to.equal(underlyingAmount)
    })

    it('it doesnt allow you to directly borrow money', async () => {
        const now = Math.floor(Date.now() / 1000)

        // Using a user account
        let exafinUser = exafin.connect(user)

        // If you expect on the TX, the await goes outside of the expect
        // If you expect on the Result, the await goes inside of the expect
        await expect(
            exafinUser.borrow(user.address, parseUnits("1"), now)
        ).to.be.revertedWith("Ownable: caller is not the owner")
    })

});
