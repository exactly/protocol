import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { errorGeneric, ExactlyEnv, ProtocolError } from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

Error.stackTraceLimit = Infinity;

describe("Oracle", function () {
  let exactlyEnv: ExactlyEnv;

  let exactlyOracle: Contract;
  let chainlinkFeedRegistry: Contract;
  let underlyingToken: Contract;

  // Oracle price is in 10**8
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
    underlyingToken = exactlyEnv.getUnderlying("DAI");
    
    const ChainlinkFeedRegistryMock = await ethers.getContractFactory("SomeChainlinkFeedRegistry");
    chainlinkFeedRegistry = await ChainlinkFeedRegistryMock.deploy();
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

  it("it returns a positive and valid price value", async () => {
    let priceOfEth = await exactlyOracle.getAssetPrice("ETH");
    let priceOfDai = await exactlyOracle.getAssetPrice("DAI");

    expect(priceOfEth).to.be.equal(tokensUSDPrice.get("ETH"));
    expect(priceOfDai).to.be.equal(tokensUSDPrice.get("DAI"));
  });

  it("it fails when price value is zero", async () => {
    await chainlinkFeedRegistry.setPrice(underlyingToken.address, "0x0000000000000000000000000000000000000348", 0);

    await expect(
      exactlyOracle.getAssetPrice("DAI")
    ).to.be.revertedWith(errorGeneric(ProtocolError.PRICE_ERROR));
  });

  it("it fails when price value is lower than zero", async () => {
    await chainlinkFeedRegistry.setPrice(underlyingToken.address, "0x0000000000000000000000000000000000000348", -10);

    await expect(
      exactlyOracle.getAssetPrice("DAI")
    ).to.be.revertedWith(errorGeneric(ProtocolError.PRICE_ERROR));
  });

  it("it fails when asset symbol is invalid", async () => {
    await expect(
      exactlyOracle.getAssetPrice("INVALID")
    ).to.be.reverted;
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
