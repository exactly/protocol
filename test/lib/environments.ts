import { ethers } from 'hardhat';
import { MakerLabels, MakerDemoValues } from './config'
import { id } from 'ethers/lib/utils'
import { Contract, BigNumber } from "ethers"
import { DSSMath } from './dssmath'

export class MakerEnv {
  vat: Contract
  weth: Contract
  wethJoin: Contract
  dai: Contract
  daiJoin: Contract
  chai: Contract
  pot: Contract


  constructor(
    vat: Contract,
    weth: Contract,
    wethJoin: Contract,
    dai: Contract,
    daiJoin: Contract,
    chai: Contract,
    pot: Contract
  ) {
    this.vat = vat
    this.weth = weth
    this.wethJoin = wethJoin
    this.dai = dai
    this.daiJoin = daiJoin
    this.chai = chai
    this.pot = pot
  }

  public static async setup() {
    const Vat = await ethers.getContractFactory("Vat");
    const GemJoin = await ethers.getContractFactory("GemJoin");
    const Weth = await ethers.getContractFactory("WETH10");
    const Dai = await ethers.getContractFactory("Dai");
    const DaiJoin = await ethers.getContractFactory("DaiJoin");
    const Chai = await ethers.getContractFactory("Chai");
    const Pot = await ethers.getContractFactory("Pot");

    // Set up vat, join and weth
    const weth = await Weth.deploy()
    await weth.deployed();

    const vat = await Vat.deploy()
    await vat.deployed();

    await vat.init(MakerLabels.WETH)
    const wethJoin = await GemJoin.deploy(vat.address, MakerLabels.WETH, weth.address)
    await wethJoin.deployed();

    // Setup DAI
    const dai = await Dai.deploy(31337)
    await dai.deployed();
    const daiJoin = await DaiJoin.deploy(vat.address, dai.address)
    await daiJoin.deployed();

    // Setup pot
    const pot = await Pot.deploy(vat.address)
    await pot.deployed()
    await pot.setChi(MakerDemoValues.chi1)
    
    // Setup chai
    const chai = await Chai.deploy(vat.address, pot.address, daiJoin.address, dai.address)
    await chai.deployed()

    // Setup vat
    await vat.functions['file(bytes32,bytes32,uint256)'](MakerLabels.WETH, MakerLabels.spotLabel, MakerDemoValues.spot)
    await vat.functions['file(bytes32,bytes32,uint256)'](MakerLabels.WETH, MakerLabels.upperBoundLineLabelForCollateral, MakerDemoValues.limits)
    await vat.functions['file(bytes32,uint256)'](MakerLabels.upperBoundLineLabelForAll, MakerDemoValues.limits)
    await vat.fold(MakerLabels.WETH, vat.address, DSSMath.subBN(MakerDemoValues.rate1, DSSMath.toRay(1))) // Fold only the increase from 1.0
    // ^^ https://docs.makerdao.com/smart-contract-modules/rates-module#stability-fee-accumulation

    // Permissions
    await vat.rely(vat.address)
    await vat.rely(wethJoin.address)
    await vat.rely(daiJoin.address)
    await vat.rely(pot.address)
    await dai.rely(daiJoin.address)

    return new MakerEnv(vat, weth, wethJoin, dai, daiJoin, chai, pot)
  }

}

export class ExactlyEnv {
  maker: MakerEnv
  treasury: Contract
  pawnbroker: Contract

  constructor(maker: MakerEnv, treasury: Contract, pawnbroker: Contract) {
    this.maker = maker
    this.treasury = treasury
    this.pawnbroker = pawnbroker
  }

  public static async setupTreasury(maker: MakerEnv) {
    const Treasury = await ethers.getContractFactory("Treasury")
    const treasury = await Treasury.deploy(
      maker.vat.address,
      maker.weth.address,
      maker.wethJoin.address,
      maker.dai.address,
      maker.daiJoin.address,
      maker.chai.address,
      maker.pot.address
    )

    await treasury.deployed()

    return treasury
  }

  public static async setupPawnbroker(treasury: Contract) {
    const Pawnbroker = await ethers.getContractFactory("Pawnbroker");

    const pawnbroker = await Pawnbroker.deploy(treasury.address)
    await pawnbroker.deployed();

    const treasuryFunctions = ['pushWeth', 'pullWeth'].map((func) =>
      id(func + '(address,uint256)').slice(0,10) // "0x" + bytes4 => 10 chars
    )
    await treasury.batchOrchestrate(pawnbroker.address, treasuryFunctions)

    return pawnbroker
  }

  public static async setup() {
    const maker = await MakerEnv.setup()
    const treasury = await this.setupTreasury(maker)
    const pawnbroker = await this.setupPawnbroker(treasury)
    return new ExactlyEnv(maker, treasury, pawnbroker)
  }

  // Convert eth to weth and post it to fyDai
  public async postWeth(user: string, _wethTokens: BigNumber) {
    await this.maker.weth.deposit({ from: user, value: _wethTokens.toString() })
    await this.maker.weth.approve(this.treasury.address, _wethTokens, { from: user })
    await this.pawnbroker.post(MakerLabels.WETH, user, user, _wethTokens, { from: user })
  }

}
