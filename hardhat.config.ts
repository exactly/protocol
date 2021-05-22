import { task } from "hardhat/config";
import { HardhatUserConfig } from "hardhat/types";
import "@nomiclabs/hardhat-waffle";
import "@nomiclabs/hardhat-solhint";
import "@openzeppelin/hardhat-upgrades";
import "solidity-coverage";
import "hardhat-abi-exporter";
import fs from 'fs';

task("accounts", "Prints the list of accounts", async (args, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(await account.address);
  }
});

const ALCHEMY_API_KEY = "DsGLl69IRAWy4BM4fVlUOOlMsr40OWHO";
const ROPSTEN_PRIVATE_KEY = fs.readFileSync('.secret','utf8');

const config: HardhatUserConfig = {
    solidity: "0.8.0",
    networks: {
        rinkeby: {
            url: `https://eth-rinkeby.alchemyapi.io/v2/${ALCHEMY_API_KEY}`,
            accounts: [`0x${ROPSTEN_PRIVATE_KEY}`]
        }
    }
};
export default config;
