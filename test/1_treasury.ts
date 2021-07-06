import { expect } from "chai";
import { ethers } from "hardhat"
import { Contract, BigNumber } from "ethers"
import { id } from 'ethers/lib/utils'
import { MakerEnv, ExactlyEnv } from './lib/environments'
import { MakerLabels } from './lib/config'
import { signERC2612Permit } from 'eth-permit';

Error.stackTraceLimit = Infinity;

describe("Treasury", function() {
  let treasury: Contract
  let vat: Contract
  let weth: Contract
  let wethJoin: Contract

  let ownerAddress: string
  let userAddress: string

  beforeEach(async () => {
    const [owner, user] = await ethers.getSigners()
    ownerAddress = await owner.getAddress()
    userAddress = await user.getAddress()

    const maker = await MakerEnv.setup()
    treasury = await ExactlyEnv.setupTreasury(maker)
    vat = maker.vat
    weth = maker.weth
    wethJoin = maker.wethJoin

    // Setup tests - Allow owner to interact directly with Treasury, not for production
    const treasuryFunctions = ['pushWeth', 'pullWeth'].map((func) =>
      id(func + '(address,uint256)').slice(0,10) // "0x" + bytes4 => 10 chars
    )

    await treasury.batchOrchestrate(ownerAddress, treasuryFunctions)
  })

  it('allows to post collateral', async () => {
    expect(await weth.balanceOf(wethJoin.address)).to.equal(0)

    let wethAmount = ethers.utils.parseEther('2.5')

    await weth.deposit({ from: ownerAddress, value: wethAmount })
    await weth.approve(treasury.address, wethAmount, { from: ownerAddress })
    await treasury.pushWeth(ownerAddress, wethAmount, { from: ownerAddress })

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
    await weth.permit(ownerAddress, treasury.address, wethAmount.toString(), result.deadline, result.v, result.r, result.s, {
      from: ownerAddress,
    });

    // tell the treasury to move money to weth
    await treasury.pushWeth(ownerAddress, wethAmount, { from: ownerAddress })

    // Test transfer of collateral to weth adapter
    expect(await weth.balanceOf(wethJoin.address)).to.equal(wethAmount)

    // Test collateral registering via `frob`
    expect((await vat.urns(MakerLabels.WETH, treasury.address)).ink).to.equal(wethAmount)
  })

  describe('with added collateral', () => {
    let wethAmount: BigNumber
    beforeEach(async () => {
      wethAmount = ethers.utils.parseEther('0.5')
      await weth.deposit({ from: ownerAddress, value: wethAmount })
      await weth.approve(treasury.address, wethAmount, { from: ownerAddress })
      await treasury.pushWeth(ownerAddress, wethAmount, { from: ownerAddress })
    })

    it('allows to withdraw collateral for user', async () => {
      expect(await weth.balanceOf(userAddress)).to.equal(0)
      const ink = (await vat.urns(MakerLabels.WETH, treasury.address)).ink.toString()

      // Testing pull from treasury to user
      await treasury.pullWeth(userAddress, ink, { from: ownerAddress })

      // Verify balance is in WETH for user to be tat amount
      expect(await weth.balanceOf(userAddress)).to.equal(ink)

      // Test that collateral is out
      expect((await vat.urns(MakerLabels.WETH, treasury.address)).ink).to.equal(0)
    })
  })
});
