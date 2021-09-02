import { expect } from "chai";
import { ethers } from "hardhat"
import { parseUnits } from "@ethersproject/units";
import { Contract, BigNumber } from "ethers"
import { parseBorrowEvent, parseLendEvent } from "./exactlyUtils";

describe("Exafront", function() {

    let oracle: Contract
    let exaFront: Contract

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

    let exafinContracts = new Map<string, Contract>();
    let underlyingContracts = new Map<string, Contract>();

    beforeEach(async () => {
        const [owner, user] = await ethers.getSigners()
        ownerAddress = await owner.getAddress()
        userAddress = await user.getAddress()

        const SomeOracle = await ethers.getContractFactory("SomeOracle")
        oracle = await SomeOracle.deploy()
        await oracle.deployed()
        
        const ExaFront = await ethers.getContractFactory("ExaFront")
        exaFront = await ExaFront.deploy(oracle.address)
        await exaFront.deployed()

        // We have to enable all the Exafins in the ExaFront
        await Promise.all(Array.from(tokensCollateralRate.keys()).map(async tokenName => {
            const totalSupply = ethers.utils.parseUnits("100000000000", 18);
            const SomeToken = await ethers.getContractFactory("SomeToken")
            const underlyingToken = await SomeToken.deploy("Fake " + tokenName, "F" + tokenName, totalSupply.toString())
            await underlyingToken.deployed()

            const Exafin = await ethers.getContractFactory("Exafin")
            const exafin = await Exafin.deploy(underlyingToken.address, tokenName)
            await exafin.deployed();
            await exafin.transferOwnership(exaFront.address);

            // Mock PriceOracle setting dummy price
            await oracle.setPrice(tokenName, tokensUSDPrice.get(tokenName))
            // Enable Market for Exafin-TOKEN by setting the collateral rates
            await exaFront.enableMarket(exafin.address, tokensCollateralRate.get(tokenName))

            // Handy maps with all the exafins and underlying tokens
            exafinContracts.set(tokenName, exafin)
            underlyingContracts.set(tokenName, underlyingToken)
        }))
    })

    it('we deposit dai & eth to the protocol and we use them both for collateral to take a loan', async () => {
        const exafinDai = exafinContracts.get('DAI')!
        const dai = underlyingContracts.get('DAI')!
        const now = Math.floor(Date.now() / 1000)

        // we borrow Dai to the protocol
        const amountDAI = parseUnits("100", 18)
        await dai.approve(exafinDai.address, amountDAI)
        let txDAI = await exafinDai.borrowFrom(ownerAddress, amountDAI, now)
        let borrowDAIEvent = await parseBorrowEvent(txDAI)

        expect(await dai.balanceOf(exafinDai.address)).to.equal(amountDAI)

        // we make it count as collateral (DAI)
        await exaFront.enterMarkets([exafinDai.address])

        const exafinETH = exafinContracts.get('ETH')!
        const eth = underlyingContracts.get('ETH')!

        // we borrow Eth to the protocol
        const amountETH = parseUnits("1", 18)
        await eth.approve(exafinETH.address, amountETH)
        let txETH = await exafinETH.borrowFrom(ownerAddress, amountETH, now)
        let borrowETHEvent = await parseBorrowEvent(txETH)

        expect(await eth.balanceOf(exafinETH.address)).to.equal(amountETH)

        // we make it count as collateral (ETH)
        await exaFront.enterMarkets([exafinETH.address])

        let liquidity = (await exaFront.getAccountLiquidity(ownerAddress, now))[1]
        let collaterDAI = amountDAI.add(borrowDAIEvent.commission).mul(tokensCollateralRate.get("DAI")!).div(parseUnits("1", 18)).mul(tokensUSDPrice.get("DAI")!).div(parseUnits("1", 6))
        let collaterETH = amountETH.add(borrowETHEvent.commission).mul(tokensCollateralRate.get("ETH")!).div(parseUnits("1", 18)).mul(tokensUSDPrice.get("ETH")!).div(parseUnits("1", 6))

        expect(liquidity).to.be.equal((collaterDAI.add(collaterETH)))
    })
});
