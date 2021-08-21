import { utils } from 'ethers'
import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { DeployFunction } from 'hardhat-deploy/types'
import fs from 'fs'
import YAML from 'yaml'

const file = fs.readFileSync('./deploy/config.yml', 'utf8')
const config = YAML.parse(file)

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const [deployer] = await hre.getUnnamedAccounts()
  const exafin = await hre.deployments.deploy('Exafin', {
    from: deployer,
    args: ["0x95b58a6bff3d14b7db2f5cb5f0ad413dc2940658"], // TODO: replace this for the value in config
    log: true
  })
}

func.skip = (hre: HardhatRuntimeEnvironment) => Promise.resolve(hre.network.name === 'mainnet')
func.tags = ['test']

export default func
