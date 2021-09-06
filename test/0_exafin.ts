import { expect } from "chai"
import { ethers } from "hardhat"
import { Contract, BigNumber } from "ethers"
import { ExactlyEnv, ExaTime, parseBorrowEvent, parseSupplyEvent } from "./exactlyUtils"
import { formatUnits, parseUnits } from "ethers/lib/utils"
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers"

Error.stackTraceLimit = Infinity

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
    let now: number
    let exaTime: ExaTime 
  
    beforeEach(async () => {
        [owner, user] = await ethers.getSigners()

        exactlyEnv = await ExactlyEnv.create(tokensUSDPrice, tokensCollateralRate)

        underlyingToken = exactlyEnv.getUnderlying("DAI")
        exafin = exactlyEnv.getExafin("DAI")
        exaFront = exactlyEnv.exaFront

        // From Owner to User
        underlyingToken.transfer(user.address, parseUnits("100"))

        exaTime = new ExaTime() // Defaults to now
        now = exaTime.timestamp
    })

    it('it allows to give money to a pool', async () => {
        const underlyingAmount = parseUnits("100")
        await underlyingToken.approve(exafin.address, underlyingAmount)

        let tx = await exafin.supply(owner.address, underlyingAmount, now)
        let event = await parseSupplyEvent(tx)

        expect(event.from).to.equal(owner.address)
        expect(event.amount).to.equal(underlyingAmount)
        expect(event.maturityDate).to.equal(exaTime.nextPoolID().timestamp)

        expect(await underlyingToken.balanceOf(exafin.address)).to.equal(underlyingAmount)
    })

    it('it allows you to borrow money', async () => {
        let exafinUser = exafin.connect(user)
        let exaFrontUser = exaFront.connect(user)
        let underlyingTokenUser = underlyingToken.connect(user)

        await underlyingTokenUser.approve(exafin.address, parseUnits("1"))
        await exafinUser.supply(user.address, parseUnits("1"), now)
        await exaFrontUser.enterMarkets([exafinUser.address])
        expect(await exafinUser.borrow(user.address, parseUnits("0.8"), now)).to.emit(exafinUser, "Borrowed")
    })

    it('it doesnt allow user to borrow money because not collateralized enough', async () => {
        let exafinUser = exafin.connect(user)
        let exaFrontUser = exaFront.connect(user)
        let underlyingTokenUser = underlyingToken.connect(user)

        await underlyingTokenUser.approve(exafin.address, parseUnits("1"))
        await exafinUser.supply(user.address, parseUnits("1"), now)
        await exaFrontUser.enterMarkets([exafinUser.address])
        await expect(exafinUser.borrow(user.address, parseUnits("0.9"), now)).to.be.reverted
    })

    it('Calculates the right rate to supply', async () => {
        let exafinUser = exafin.connect(user)
        let underlyingTokenUser = underlyingToken.connect(user)
        let unitsToSupply = parseUnits("1")

        let [rateSupplyToApply, poolStateAfterSupply] = await exafinUser.rateForSupply(unitsToSupply, now)

        // We verify that the state of the pool is what we suppose it is
        expect(poolStateAfterSupply[1]).to.be.equal(unitsToSupply)
        expect(poolStateAfterSupply[0]).to.be.equal(0)

        // We supply the money
        await underlyingTokenUser.approve(exafin.address, unitsToSupply)
        let tx = await exafinUser.supply(user.address, unitsToSupply, now)
        let supplyEvent = await parseSupplyEvent(tx)

        // It should be the base rate since there are no other deposits
        let nextExpirationDate = exaTime.nextPoolID().timestamp
        let daysToExpiration = exaTime.daysDiffWith(nextExpirationDate)
        let yearlyRateProjected = BigNumber.from(rateSupplyToApply).mul(365).div(daysToExpiration)

        // Expected "19999999999999985" to be within 20 of 20000000000000000
        expect(BigNumber.from(yearlyRateProjected)).to.be.closeTo(exactlyEnv.baseRate, 20)

        // We expect that the actual rate was taken when we submitted the supply transaction
        expect(supplyEvent.commission).to.be.closeTo(unitsToSupply.mul(rateSupplyToApply).div(parseUnits("1")), 20)
    })

    it('Calculates the right rate to borrow', async () => {
        let exafinUser = exafin.connect(user)
        let underlyingTokenUser = underlyingToken.connect(user)
        let unitsToSupply = parseUnits("1")
        let unitsToBorrow = parseUnits("0.8")
        
        await underlyingTokenUser.approve(exafin.address, unitsToSupply)
        await exafinUser.supply(user.address, unitsToSupply, now)

        let [rateBorrowToApply, poolStateAfterBorrow] = await exafinUser.rateToBorrow(unitsToBorrow, now)

        expect(poolStateAfterBorrow[1]).to.be.equal(unitsToSupply)
        expect(poolStateAfterBorrow[0]).to.be.equal(unitsToBorrow)

        let tx = await exafinUser.borrow(user.address, unitsToBorrow, now)
        expect(tx).to.emit(exafinUser, "Borrowed")
        let borrowEvent = await parseBorrowEvent(tx)

        // It should be the base rate since there are no other deposits
        let nextExpirationDate = exaTime.nextPoolID().timestamp
        let daysToExpiration = exaTime.daysDiffWith(nextExpirationDate)

        // We just receive the multiplying factor for the amount "rateBorrowToApply"
        // so by multiplying we get the APY
        let yearlyRateProjected = BigNumber.from(rateBorrowToApply)
            .mul(365)
            .div(daysToExpiration)

        // This Rate is purely calculated on JS/TS side
        let yearlyRateCalculated = exactlyEnv.baseRate
            .add(exactlyEnv.marginRate)
            .add(exactlyEnv.slopeRate
                .mul(unitsToBorrow)
                .div(unitsToSupply))

        // Expected "85999999999999996" to be within 20 of 86000000000000000
        expect(yearlyRateProjected).to.be.closeTo(yearlyRateCalculated, 20)

        // We expect that the actual rate was taken when we submitted the borrowing transaction
        expect(borrowEvent.commission).to.be.closeTo(unitsToBorrow.mul(rateBorrowToApply).div(parseUnits("1")), 20)
    })

})
