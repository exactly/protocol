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
    let exaFront: Contract

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
        exaFront = exactlyEnv.exaFront

        // From Owner to User
        underlyingToken.transfer(user.address, parseUnits("100"))
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

    it('it allows you to borrow money', async () => {
        const now = Math.floor(Date.now() / 1000)

        let exafinUser = exafin.connect(user)
        let exaFrontUser = exaFront.connect(user)
        let underlyingTokenUser = underlyingToken.connect(user)

        await underlyingTokenUser.approve(exafin.address, parseUnits("1"))
        await exafinUser.supply(user.address, parseUnits("1"), now)
        await exaFrontUser.enterMarkets([exafinUser.address])
        expect(await exafinUser.borrow(user.address, parseUnits("0.8"), now)).to.emit(exafinUser, "Borrowed")
    })

    it('it doesnt allow user to borrow money because not collateralized enough', async () => {
        const now = Math.floor(Date.now() / 1000)

        let exafinUser = exafin.connect(user)
        let exaFrontUser = exaFront.connect(user)
        let underlyingTokenUser = underlyingToken.connect(user)

        await underlyingTokenUser.approve(exafin.address, parseUnits("1"))
        await exafinUser.supply(user.address, parseUnits("1"), now)
        await exaFrontUser.enterMarkets([exafinUser.address])
        await expect(exafinUser.borrow(user.address, parseUnits("0.9"), now)).to.be.reverted
    })

});
