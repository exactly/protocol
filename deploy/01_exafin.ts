import { parseUnits } from '@ethersproject/units'
import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { DeployFunction } from 'hardhat-deploy/types'
import fs from 'fs'
import YAML from 'yaml'

let tokensCollateralRate = new Map([
  ['DAI', parseUnits("0.8", 18)],
  ['WETH', parseUnits("0.7", 18)]
]);

// We're doing a little trick here. Compound's oracle has ETH (not wrapped ETH).
// but we're going to use all ERC20's in our EXAFIN's contracts, so we're passing
// the name for the oracle as an argument to the contracts
let nameForOracle = new Map([
  ['DAI', "DAI"],
  ['WETH', "ETH"]
]);

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const file = fs.readFileSync('./config.yml', 'utf8')
  const config = YAML.parse(file)

  const [deployer] = await hre.getUnnamedAccounts()

  let tokensForNetwork = config.token_addresses[hre.network.name].assets
  let priceOracleAddress = config.token_addresses[hre.network.name].price_oracle

  const exaFront = await hre.deployments.deploy("ExaFront", {
    from: deployer,
    args: [priceOracleAddress],
    log: true
  })

  for (const [tokenName, tokenAddress] of Object.entries(tokensForNetwork)) { 

    console.log("------")
    console.log("Exafin for %s will use: %s", tokenName, tokenAddress)

    const exafin = await hre.deployments.deploy('Exafin', {
      from: deployer,
      args: [tokenAddress, nameForOracle.get(tokenName)],
      log: true
    })

    // We transfer ownership of Exafin to ExaFront
    await hre.deployments.execute('Exafin',
      { from: deployer },
      'transferOwnership',
      exaFront.address
    );

    // We enable this ExaFin Market on ExaFront
    await hre.deployments.execute('ExaFront',
      { from: deployer },
      'enableMarket',
      exafin.address,
      tokensCollateralRate.get(tokenName)
    );

    console.log("Exafin %s deployed to: %s", tokenName, exafin.address)
  }
}

func.skip = (hre: HardhatRuntimeEnvironment) => Promise.resolve(hre.network.name === 'mainnet')
func.tags = ['test']

export default func
