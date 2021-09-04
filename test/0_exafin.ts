import { expect } from "chai";
import { ethers } from "hardhat"
import { Contract, BigNumber } from "ethers"
import { ExactlyEnv, parseBorrowEvent, parseSupplyEvent } from "./exactlyUtils"
import { parseUnits } from "ethers/lib/utils";

Error.stackTraceLimit = Infinity;

describe("Exafin", function() {

    let exactlyEnv: ExactlyEnv

    let underlyingToken: Contract
    let exafin: Contract

    let ownerAddress: string
    let userAddress: string

    let tokensCollateralRate = new Map([
        ['DAI', parseUnits("0.8", 18)],
        ['ETH', parseUnits("0.7", 18)]
    ]);

    // Oracle price is in 10**6
    let tokensUSDPrice = new Map([
        ['DAI', parseUnits("1", 6)],
        ['ETH', parseUnits("3100", 6)]
    ]);
  
    beforeEach(async () => {
        const [owner, user] = await ethers.getSigners()
        ownerAddress = await owner.getAddress()
        userAddress = await user.getAddress()

        exactlyEnv = await ExactlyEnv.create(tokensUSDPrice, tokensCollateralRate)

        underlyingToken = exactlyEnv.getUnderlying("DAI")
        exafin = exactlyEnv.getExafin("DAI")
   })

    it('it allows to give money to a pool', async () => {
        const now = Math.floor(Date.now() / 1000)
        const underlyingAmount = parseUnits("100")
        await underlyingToken.approve(exafin.address, underlyingAmount)

        let tx = await exafin.supply(ownerAddress, underlyingAmount, now)
        let event = await parseSupplyEvent(tx)

        expect(event.from).to.equal(ownerAddress)
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
        await exafin.supply(ownerAddress, borrowAmount, now)

        let tx = await exafin.borrow(userAddress, lendAmount, now)
        let event = await parseBorrowEvent(tx) 

        expect(event.to).to.equal(userAddress)
        expect(event.amount).to.equal(lendAmount)
        expect(event.maturityDate).to.equal(now - (now % (86400 * 30)) + 86400 * 30)
        expect(await underlyingToken.balanceOf(userAddress)).to.equal(lendAmount)
    })

});
