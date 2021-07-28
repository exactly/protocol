import { expect } from "chai";
import { ethers } from "hardhat"
import { Contract, BigNumber } from "ethers"
import { id } from 'ethers/lib/utils'
import { MakerEnv, ExactlyEnv } from './lib/environments'
import { MakerLabels } from './lib/config'
import { signERC2612Permit } from 'eth-permit';

Error.stackTraceLimit = Infinity;

describe("Treasury", function() {
  let exactly: ExactlyEnv
  let maker: MakerEnv

  let wethJoin: Contract
  let treasury: Contract
  let weth: Contract
  let vat: Contract

  let ownerAddress: string
  let userAddress: string
  
  beforeEach(async () => {
    const [owner, user] = await ethers.getSigners()
    ownerAddress = await owner.getAddress()
    userAddress = await user.getAddress()

    exactly = await ExactlyEnv.setup()
    await exactly.enableTreasuryFunctionsFor(ownerAddress)
    await exactly.enableTreasuryFunctionsFor(exactly.pawnbroker.address)

    wethJoin = exactly.maker.wethJoin
    vat = exactly.maker.vat
    treasury = exactly.treasury
    weth = exactly.weth
  })

  it('allows to post collateral', async () => {
    expect(await weth.balanceOf(wethJoin.address)).to.equal(0)

    let wethAmount = ethers.utils.parseEther('2.5')

    await weth.deposit({ value: wethAmount })
    await weth.approve(treasury.address, wethAmount)
    await treasury.pushWeth(ownerAddress, wethAmount)

    // Test transfer of collateral to weth adapter
    expect(await weth.balanceOf(wethJoin.address)).to.equal(wethAmount)

    // Test collateral registering via `frob`
    expect((await vat.urns(MakerLabels.WETH, treasury.address)).ink).to.equal(wethAmount)
  })

  it('allows to post collateral with permit', async () => {
    expect(await weth.balanceOf(wethJoin.address)).to.equal(0)

    let wethAmount = ethers.utils.parseEther('2.5')

    await weth.deposit({ from: ownerAddress, value: wethAmount })

    // Sign message using injected provider.
    const result = await signERC2612Permit(ethers.provider, weth.address, ownerAddress, treasury.address, wethAmount.toString());
    await weth.permit(ownerAddress, treasury.address, wethAmount.toString(), result.deadline, result.v, result.r, result.s);

    // tell the treasury to move money to weth
    await treasury.pushWeth(ownerAddress, wethAmount)

    // Test transfer of collateral to weth adapter
    expect(await weth.balanceOf(wethJoin.address)).to.equal(wethAmount)

    // Test collateral registering via `frob`
    expect((await vat.urns(MakerLabels.WETH, treasury.address)).ink).to.equal(wethAmount)
  })

  describe('with added collateral', () => {
    let wethAmount: BigNumber
    beforeEach(async () => {
      wethAmount = ethers.utils.parseEther('0.5')
      await weth.deposit({ value: wethAmount })
      await weth.approve(treasury.address, wethAmount)
      await treasury.pushWeth(ownerAddress, wethAmount)
    })

    it('allows to withdraw collateral for user', async () => {
      expect(await weth.balanceOf(userAddress)).to.equal(0)
      const ink = (await vat.urns(MakerLabels.WETH, treasury.address)).ink.toString()

      // Testing pull from treasury to user
      await treasury.pullWeth(userAddress, ink)

      // Verify balance is in WETH for user to be tat amount
      expect(await weth.balanceOf(userAddress)).to.equal(ink)

      // Test that collateral is out
      expect((await vat.urns(MakerLabels.WETH, treasury.address)).ink).to.equal(0)
    })
  })
});
