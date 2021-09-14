import { parseUnits } from "@ethersproject/units";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import fs from "fs";
import YAML from "yaml";
import { ethers } from "hardhat";

let tokensCollateralRate = new Map([
  ["DAI", parseUnits("0.8", 18)],
  ["WETH", parseUnits("0.7", 18)],
  ["USDT", parseUnits("0.4", 18)],
]);

// We're doing a little trick here. Compound's oracle has ETH (not wrapped ETH).
// but we're going to use all ERC20's in our EXAFIN's contracts, so we're passing
// the name for the oracle as an argument to the contracts
let nameForOracle = new Map([
  ["DAI", "DAI"],
  ["WETH", "ETH"],
  ["USDT", "USDT"],
]);

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const file = fs.readFileSync("./config.yml", "utf8");
  const config = YAML.parse(file);

  const [deployer] = await hre.getUnnamedAccounts();

  let tokensForNetwork = config.token_addresses[hre.network.name].assets;
  let priceOracleAddress =
    config.token_addresses[hre.network.name].price_oracle;

  const exaFront = await hre.deployments.deploy("ExaFront", {
    from: deployer,
    args: [priceOracleAddress],
    log: true,
  });

  async function impersonate(
    address = "0x2c8fbb630289363ac80705a1a61273f76fd5a161"
  ) {
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [address],
    });

    const signer = await ethers.provider.getSigner(address);
    return signer;
  }

  for (const symbol of Object.keys(tokensForNetwork)) {
    const { name, address } = tokensForNetwork[symbol];
    console.log("------");
    console.log(
      "Exafin for %s will use: %s",
      symbol,
      address,
      exaFront.address
    );

    const exafin = await hre.deployments.deploy("Exafin", {
      from: deployer,
      args: [address, nameForOracle.get(symbol), exaFront.address],
      log: true,
    });

    // We transfer ownership of Exafin to ExaFront
    await hre.deployments.execute(
      "Exafin",
      { from: deployer },
      "transferOwnership",
      exaFront.address
    );

    // We enable this ExaFin Market on ExaFront
    await hre.deployments.execute(
      "ExaFront",
      { from: deployer },
      "enableMarket",
      exafin.address,
      tokensCollateralRate.get(symbol),
      symbol,
      name
    );

    console.log("Exafin %s deployed to: %s", symbol, exafin.address);

    let dai = await ethers.getContractAt(
      "IERC20",
      "0x6B175474E89094C44Da98b954EedeAC495271d0F"
    );
    const whaleSigner = await impersonate();

    dai = dai.connect(whaleSigner);
    await dai.transfer(
      "0xd1Cd4c2e15Bf0D05796c7C9f7c0Eaba30119f454",
      ethers.utils.parseEther("100")
    );
  }
};

func.skip = (hre: HardhatRuntimeEnvironment) =>
  Promise.resolve(hre.network.name === "mainnet");
func.tags = ["test"];

export default func;
