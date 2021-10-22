import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { ExactlyEnv } from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

Error.stackTraceLimit = Infinity;

describe("Oracle", function () {
  let exactlyEnv: ExactlyEnv;

  let exactlyOracle: Contract;

  // Oracle price is in 10**6
  let tokensUSDPrice = new Map([
    ["DAI", parseUnits("1", 8)],
    ["ETH", parseUnits("3100", 8)],
  ]);

  let tokensCollateralRate = new Map([
    ["DAI", parseUnits("0.8", 18)],
    ["ETH", parseUnits("0.7", 18)],
  ]);

  let mariaUser: SignerWithAddress;
  let johnUser: SignerWithAddress;
  let owner: SignerWithAddress;

  let snapshot: any;

  beforeEach(async () => {
    [owner, mariaUser, johnUser] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(tokensUSDPrice, tokensCollateralRate);
    
    const ChainlinkFeedRegistryMock = await ethers.getContractFactory("SomeChainlinkFeedRegistry");
    let chainlinkFeedRegistry = await ChainlinkFeedRegistryMock.deploy();
    await chainlinkFeedRegistry.deployed();

    let tokenAddresses = new Array();
    let tokenNames = new Array();
    await Promise.all(
      Array.from(tokensCollateralRate.keys()).map(async (tokenName) => {
        const token = exactlyEnv.getUnderlying(tokenName);
        tokenAddresses.push(token.address);
        tokenNames.push(tokenName);

        await chainlinkFeedRegistry.setPrice(token.address, "0x0000000000000000000000000000000000000348", tokensUSDPrice.get(tokenName));
      })
    );

    const ExactlyOracle = await ethers.getContractFactory("ExactlyOracle");
    exactlyOracle = await ExactlyOracle.deploy(chainlinkFeedRegistry.address, tokenNames, tokenAddresses, "0x0000000000000000000000000000000000000348", 1);
    await exactlyOracle.deployed();
    await exactlyOracle.setAssetSources(tokenNames, tokenAddresses);
    await exactlyEnv.setOracle(exactlyOracle.address);

    // This can be optimized (so we only do it once per file, not per test)
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  it("Get asset price returns valid value", async () => {
    let priceOfEth = await exactlyOracle.getAssetPrice("ETH");

    expect(priceOfEth).to.be.equal(tokensUSDPrice.get("ETH"));
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
