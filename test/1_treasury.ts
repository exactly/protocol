import { expect } from "chai";
import { ethers } from "hardhat"
import { Contract } from "ethers"
import { id } from 'ethers/lib/utils'
import { MakerEnv, ExactlyEnv } from './lib/environments'
import { MakerLabels } from './lib/config'

Error.stackTraceLimit = Infinity;

describe("Treasury", function() {
  let treasury: Contract
  let vat: Contract
  let weth: Contract
  let wethJoin: Contract

  let ownerAddress: string

  beforeEach(async () => {
    const [owner] = await ethers.getSigners()
    ownerAddress = await owner.getAddress()

    const maker = await MakerEnv.setup()
    treasury = await ExactlyEnv.setupTreasury(maker)
    vat = maker.vat
    weth = maker.weth
    wethJoin = maker.wethJoin

    // Setup tests - Allow owner to interact directly with Treasury, not for production
    const treasuryFunctions = ['pushWeth', 'pullWeth'].map((func) =>
      id(func + '(address,uint256)').slice(0,10)
      // ^ "0x" + bytes4 => 10 chars
    )

    await treasury.batchOrchestrate(ownerAddress, treasuryFunctions)
  })

  it('allows to post collateral', async () => {
    expect(await weth.balanceOf(wethJoin.address)).to.equal(0)

    await weth.deposit({ from: ownerAddress, value: 1 })
    await weth.approve(treasury.address, 1, { from: ownerAddress })
    await treasury.pushWeth(ownerAddress, 1, { from: ownerAddress })

    // Test transfer of collateral to weth adapter
    expect(await weth.balanceOf(wethJoin.address)).to.equal(1)

    // Test collateral registering via `frob`
    expect((await vat.urns(MakerLabels.WETH, treasury.address)).ink).to.equal(1)
  })
});
