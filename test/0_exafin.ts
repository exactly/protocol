import { expect } from "chai";
import { ethers } from "hardhat"
import { Contract, BigNumber } from "ethers"
import { ExactlyEnv, parseBorrowEvent, parseSupplyEvent } from "./exactlyUtils"
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

Error.stackTraceLimit = Infinity;

describe("Exafin", function() {

    let exactlyEnv: ExactlyEnv

    let underlyingToken: Contract
    let exafin: Contract

    let tokensCollateralRate = new Map([
        ['DAI', parseUnits("0.8", 18)],
        ['ETH', parseUnits("0.7", 18)]
    ]);

    // Oracle price is in 10**6
    let tokensUSDPrice = new Map([
        ['DAI', parseUnits("1", 6)],
        ['ETH', parseUnits("3100", 6)]
    ]);

    let user: SignerWithAddress
    let owner: SignerWithAddress
  
    beforeEach(async () => {
        [owner, user] = await ethers.getSigners()

        exactlyEnv = await ExactlyEnv.create(tokensUSDPrice, tokensCollateralRate)

        underlyingToken = exactlyEnv.getUnderlying("DAI")
        exafin = exactlyEnv.getExafin("DAI")
    })

    it('it allows to give money to a pool', async () => {
        const now = Math.floor(Date.now() / 1000)
        const underlyingAmount = parseUnits("100")
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
