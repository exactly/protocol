import { expect } from 'chai'
import { ethers } from 'hardhat'
import { parseUnits } from '@ethersproject/units'
import { BigNumber, Contract } from 'ethers'
import { ProtocolError, ExactlyEnv, ExaTime, errorGeneric } from './exactlyUtils'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'

describe('Liquidations', function () {
  let auditor: Contract
  let exactlyEnv: ExactlyEnv
  let nextPoolID: number

  let bob: SignerWithAddress
  let alice: SignerWithAddress

  let exafinETH: Contract
  let eth: Contract
  let exafinDAI: Contract
  let dai: Contract
  let exafinWBTC: Contract
  let wbtc: Contract

  let mockedTokens = new Map([
    ['DAI', {decimals: 18, collateralRate: parseUnits('0.8', 18), usdPrice: parseUnits('1')}],
    ['ETH', {decimals: 18, collateralRate: parseUnits('0.7', 18), usdPrice: parseUnits('3000')}],
    ['WBTC', {decimals: 8, collateralRate: parseUnits('0.6', 8), usdPrice: parseUnits('63000')}],
  ])

  let closeFactor = parseUnits('0.5')
  let amountToBorrowDAI: BigNumber
  let owedDAI: BigNumber

  beforeEach(async () => {
    ;[alice, bob] = await ethers.getSigners()

    exactlyEnv = await ExactlyEnv.create(mockedTokens)
    auditor = exactlyEnv.auditor
    nextPoolID = new ExaTime().nextPoolID()

    exafinETH = exactlyEnv.getExafin('ETH')
    eth = exactlyEnv.getUnderlying('ETH')
    exafinDAI = exactlyEnv.getExafin('DAI')
    dai = exactlyEnv.getUnderlying('DAI')
    exafinWBTC = exactlyEnv.getExafin('WBTC')
    wbtc = exactlyEnv.getUnderlying('WBTC')

    // From alice to bob
    await dai.transfer(bob.address, parseUnits('100000'))
  })

  describe('GIVEN alice supplies USD63k worth of WBTC, USD3k worth of ETH (66k total) AND bob supplies 65kDAI', () => {
    beforeEach(async () => {
      // we supply Eth to the protocol
      const amountETH = parseUnits('1', 18)
      await eth.approve(exafinETH.address, amountETH)
      await exafinETH.supply(alice.address, amountETH, nextPoolID)

      // we supply WBTC to the protocol
      const amountWBTC = parseUnits('1', 8)
      await wbtc.approve(exafinWBTC.address, amountWBTC)
      await exafinWBTC.supply(alice.address, amountWBTC, nextPoolID)

      // bob supplies DAI to the protocol to have money in the pool
      const amountDAI = parseUnits('65000', 18)
      await dai.connect(bob).approve(exafinDAI.address, amountDAI)
      await exafinDAI.connect(bob).supply(bob.address, amountDAI, nextPoolID)
    })

    describe('AND GIVEN Alice takes the biggest loan she can (39905 DAI), collaterallization 1.65', () => {
      beforeEach(async () => {
        // we make ETH & WBTC count as collateral
        await auditor.enterMarkets([exafinETH.address, exafinWBTC.address])
        // this works because 1USD (liquidity) = 1DAI (asset to borrow)
        let liquidityInUSD = (await auditor.getAccountLiquidity(alice.address, nextPoolID))[0]
        amountToBorrowDAI = liquidityInUSD

        // bob borrows all liquidity
        await exafinDAI.borrow(amountToBorrowDAI, nextPoolID)
        ;[, owedDAI] = await exafinDAI.getAccountSnapshot(alice.address, nextPoolID)
          let liquidityAfterOracleChange = (await auditor.getAccountLiquidity(alice.address, nextPoolID))[0]
      })
      describe('AND GIVEN ETH price halves (Alices collateral goes from 66k to 38.5k), collaterallization: 0.96', () => {
        beforeEach(async () => {
          await exactlyEnv.setOracleMockPrice('WBTC', '32500')
        })

        it('THEN alices liquidity is zero', async () => {
          // We expect liquidity to be equal to zero
          let liquidityAfterOracleChange = (await auditor.getAccountLiquidity(alice.address, nextPoolID))[0]
          expect(liquidityAfterOracleChange).to.be.equal(0)
        })
        it('AND alice has a liquidity shortfall', async () => {
          let shortfall = (await auditor.getAccountLiquidity(alice.address, nextPoolID))[1]
          expect(shortfall).to.be.gt(0)
        })
        it('AND trying to repay an amount of zero fails', async () => {
          // We try to get all the ETH we can
          // We expect trying to repay zero to fail
          await expect(exafinDAI.liquidate(alice.address, 0, exafinETH.address, nextPoolID)).to.be.revertedWith(
            errorGeneric(ProtocolError.REPAY_ZERO)
          )
        })
        it('AND the position cant be liquidated by the borrower', async () => {
          // We expect self liquidation to fail
          await expect(exafinDAI.liquidate(alice.address, owedDAI, exafinETH.address, nextPoolID)).to.be.revertedWith(
            errorGeneric(ProtocolError.LIQUIDATOR_NOT_BORROWER)
          )
        })

        describe('GIVEN an insufficient allowance on the liquidator', () => {
          beforeEach(async () => {
            await dai.connect(bob).approve(exafinDAI.address, owedDAI.div(2).sub(100))
          })
          it('WHEN trying to liquidate, THEN it reverts with a TOKENS_MORE_THAN_BALANCE error', async () => {
            // We expect liquidation to fail because trying to liquidate
            // and take over a collateral that bob doesn't have enough
            await expect(
              exafinDAI.connect(bob).liquidate(alice.address, owedDAI.div(2).sub(100), exafinETH.address, nextPoolID)
            ).to.be.revertedWith(errorGeneric(ProtocolError.TOKENS_MORE_THAN_BALANCE))
          })
        })

        describe('GIVEN a sufficient allowance on the liquidator', () => {
          beforeEach(async () => {
            await dai.connect(bob).approve(exafinDAI.address, owedDAI.mul(1000))
          })
          it('WHEN liquidating slightly more than the close factor(0.5), THEN it reverts', async () => {
            // We expect liquidation to fail because trying to liquidate too much (more than close factor of the borrowed asset)
            await expect(
              exafinDAI.connect(bob).liquidate(alice.address, owedDAI.div(2).add(1000), exafinWBTC.address, nextPoolID)
            ).to.be.revertedWith(errorGeneric(ProtocolError.TOO_MUCH_REPAY))
          })
          it('AND WHEN liquidating slightly more than the close factor, THEN it succeeds', async () => {
            let closeToMaxRepay = owedDAI.mul(closeFactor).div(parseUnits('1')).sub(100000)
            await exafinDAI.connect(bob).liquidate(alice.address, closeToMaxRepay, exafinWBTC.address, nextPoolID)
          })
        })
      })
    })
  })
})
