import { ethers } from 'hardhat';
import { MakerLabels, MakerDemoValues } from './config'
import { id } from 'ethers/lib/utils'
import { Contract, BigNumber } from "ethers"
import { DSSMath } from './dssmath'

export class MakerEnv {
  vat: Contract
  wethJoin: Contract
  daiJoin: Contract

  constructor(
    vat: Contract,
    wethJoin: Contract,
    daiJoin: Contract
  ) {
    this.vat = vat
    this.wethJoin = wethJoin
    this.daiJoin = daiJoin
  }

  public static async setup(weth: Contract, dai: Contract) {
    const Vat = await ethers.getContractFactory("Vat");
    const GemJoin = await ethers.getContractFactory("GemJoin");
    const DaiJoin = await ethers.getContractFactory("DaiJoin");

    const vat = await Vat.deploy()
    await vat.deployed();

    await vat.init(MakerLabels.WETH)
    const wethJoin = await GemJoin.deploy(vat.address, MakerLabels.WETH, weth.address)
    await wethJoin.deployed();

    const daiJoin = await DaiJoin.deploy(vat.address, dai.address)
    await daiJoin.deployed();
    
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
    await dai.rely(daiJoin.address)

    return new MakerEnv(vat, wethJoin, daiJoin)
  }

}

export class ExactlyEnv {
  maker: MakerEnv
  weth: Contract
  dai: Contract
  treasury: Contract
  pawnbroker: Contract

  constructor(maker: MakerEnv, treasury: Contract, pawnbroker: Contract, weth: Contract, dai: Contract) {
    this.maker = maker
    this.treasury = treasury
    this.pawnbroker = pawnbroker
    this.weth = weth
    this.dai = dai
  }

  public static async setupTreasury(maker: MakerEnv, weth: Contract, dai: Contract, cToken: Contract) {
    const Treasury = await ethers.getContractFactory("Treasury")
    const treasury = await Treasury.deploy(
      maker.vat.address,
      weth.address,
      maker.wethJoin.address,
      dai.address,
      maker.daiJoin.address,
      cToken.address
    )

    await treasury.deployed()

    return treasury
  }

  public static async setupPawnbroker(treasury: Contract) {
    const Pawnbroker = await ethers.getContractFactory("Pawnbroker");

    const pawnbroker = await Pawnbroker.deploy(treasury.address)
    await pawnbroker.deployed()

    return pawnbroker
  }

  public static async setup() {

    const Weth = await ethers.getContractFactory("WETH10")
    const Dai = await ethers.getContractFactory("Dai")
    const CToken = await ethers.getContractFactory("CToken")

    // Set up vat, join and weth
    const weth = await Weth.deploy()
    await weth.deployed()

    // Setup DAI
    const dai = await Dai.deploy(31337)
    await dai.deployed()

    // Setup cToken
    const cToken = await CToken.deploy(dai.address)
    await cToken.deployed()

    const maker = await MakerEnv.setup(weth, dai)
    const treasury = await this.setupTreasury(maker, weth, dai, cToken)
    const pawnbroker = await this.setupPawnbroker(treasury)
    return new ExactlyEnv(maker, treasury, pawnbroker, weth, dai)
  }

  public async enableTreasuryFunctionsFor(address: string) {
    const treasuryFunctions = ['pushWeth', 'pullWeth', 'pushDai', 'pullDai'].map((func) =>
      id(func + '(address,uint256)').slice(0,10) // "0x" + bytes4 => 10 chars
    )
    await this.treasury.batchOrchestrate(address, treasuryFunctions)
  }

  public async postWeth(user: string, _wethTokens: BigNumber) {
    await this.weth.deposit({ from: user, value: _wethTokens.toString() })
    await this.weth.approve(this.treasury.address, _wethTokens, { from: user })
    await this.pawnbroker.post(MakerLabels.WETH, user, user, _wethTokens, { from: user })
  }

}
