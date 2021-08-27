import { expect } from "chai";
import { ethers } from "hardhat"
import { parseUnits } from "@ethersproject/units";
import { Contract, BigNumber } from "ethers"
import { fail } from "assert/strict";

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
       
        await Promise.all(Array.from(tokensCollateralRate.keys()).map(async tokenName => {
            const totalSupply = ethers.utils.parseUnits("100000000000", 18);
            const SomeToken = await ethers.getContractFactory("SomeToken")
            const underlyingToken = await SomeToken.deploy("Fake " + tokenName, "F" + tokenName, totalSupply.toString())
            await underlyingToken.deployed()

            const Exafin = await ethers.getContractFactory("Exafin")
            const exafin = await Exafin.deploy(underlyingToken.address, tokenName)
            await exafin.deployed();

            await oracle.setPrice(tokenName, tokensUSDPrice.get(tokenName))
            await exaFront.enableMarket(exafin.address, tokensCollateralRate.get(tokenName))

            exafinContracts.set(tokenName, exafin)
            underlyingContracts.set(tokenName, underlyingToken)
        }))
    })

    it('it allows to give money to a pool', async () => {
        const exafinDai = exafinContracts.get('DAI')!
        const dai = underlyingContracts.get('DAI')!
        const now = Math.floor(Date.now() / 1000)

        const amountDai = parseUnits("100", 18)
        await dai.approve(exafinDai.address, amountDai)
        await exafinDai.borrow(ownerAddress, amountDai, now)
        expect(await dai.balanceOf(exafinDai.address)).to.equal(amountDai)

        await exaFront.enterMarkets([exafinDai.address])

        const exafinETH = exafinContracts.get('ETH')!
        const eth = underlyingContracts.get('ETH')!

        const ethAmount = parseUnits("1", 18)
        await eth.approve(exafinETH.address, ethAmount)
        await exafinETH.borrow(ownerAddress, ethAmount, now)
        expect(await eth.balanceOf(exafinETH.address)).to.equal(ethAmount)

        await exaFront.enterMarkets([exafinETH.address])

        let liquidity = await exaFront.getAccountLiquidity(ownerAddress, now)
        console.log(liquidity[1].toString())
    })
});
