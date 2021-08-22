import { utils } from 'ethers'
import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { DeployFunction } from 'hardhat-deploy/types'
import fs from 'fs'
import YAML from 'yaml'

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const file = fs.readFileSync('./config.yml', 'utf8')
  const config = YAML.parse(file)

  const [deployer] = await hre.getUnnamedAccounts()

  console.log(hre.network.name)

  let tokensForNetwork = config.token_addresses[hre.network.name]
  for (const [tokenName, tokenAddress] of Object.entries(tokensForNetwork)) { 

    const exafin = await hre.deployments.deploy('Exafin', {
      from: deployer,
      args: [tokenAddress],
      log: true
    })  
    console.log("Exafin %s deployed to: %s", tokenName, exafin.address)
  }


}

func.skip = (hre: HardhatRuntimeEnvironment) => Promise.resolve(hre.network.name === 'mainnet')
func.tags = ['test']

export default func
