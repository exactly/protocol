import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { errorGeneric, ExactlyEnv, ProtocolError } from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

Error.stackTraceLimit = Infinity;

describe("ExactlyOracle", function () {
  let exactlyEnv: ExactlyEnv;

  let exactlyOracle: Contract;
  let chainlinkFeedRegistry: Contract;
  let underlyingToken: Contract;

  let user: SignerWithAddress;

  // Oracle price is in 10**8
  let tokensUSDPrice = new Map([
    ["DAI", parseUnits("1", 8)],
    ["ETH", parseUnits("3100", 8)],
  ]);

  let tokensCollateralRate = new Map([
    ["DAI", parseUnits("0.8", 18)],
    ["ETH", parseUnits("0.7", 18)],
  ]);

  let snapshot: any;

  beforeEach(async () => {
    [, user] = await ethers.getSigners();
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

        await chainlinkFeedRegistry.setPrice(token.address, exactlyEnv.usdAddress, tokensUSDPrice.get(tokenName));
      })
    );

    const ExactlyOracle = await ethers.getContractFactory("ExactlyOracle");
    exactlyOracle = await ExactlyOracle.deploy(chainlinkFeedRegistry.address, tokenNames, tokenAddresses, exactlyEnv.usdAddress);
    await exactlyOracle.deployed();
    await exactlyOracle.setAssetSources(tokenNames, tokenAddresses);
    await exactlyEnv.setOracle(exactlyOracle.address);

    // This can be optimized (so we only do it once per file, not per test)
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  it("GetAssetPrice returns a positive and valid price value", async () => {
    let priceOfEth = await exactlyOracle.getAssetPrice("ETH");
    let priceOfDai = await exactlyOracle.getAssetPrice("DAI");

    expect(priceOfEth).to.be.equal(tokensUSDPrice.get("ETH"));
    expect(priceOfDai).to.be.equal(tokensUSDPrice.get("DAI"));
  });

  it("GetAssetsPrices returns positive and valid price values", async () => {
    let prices = await exactlyOracle.getAssetsPrices(["ETH", "DAI"]);

    expect(prices[0]).to.be.equal(tokensUSDPrice.get("ETH"));
    expect(prices[1]).to.be.equal(tokensUSDPrice.get("DAI"));
  });

  it("GetAssetPrice should fail when price value is zero", async () => {
    await chainlinkFeedRegistry.setPrice(underlyingToken.address, exactlyEnv.usdAddress, 0);

    await expect(
      exactlyOracle.getAssetPrice("DAI")
    ).to.be.revertedWith(errorGeneric(ProtocolError.PRICE_ERROR));
  });

  it("GetAssetPrices should fail if a price value is zero", async () => {
    await chainlinkFeedRegistry.setPrice(underlyingToken.address, exactlyEnv.usdAddress, 0);

    await expect(
      exactlyOracle.getAssetsPrices(["ETH", "DAI"])
    ).to.be.revertedWith(errorGeneric(ProtocolError.PRICE_ERROR));
  });

  it("GetAssetPrice should fail when price value is lower than zero", async () => {
    await chainlinkFeedRegistry.setPrice(underlyingToken.address, exactlyEnv.usdAddress, -10);

    await expect(
      exactlyOracle.getAssetPrice("DAI")
    ).to.be.revertedWith(errorGeneric(ProtocolError.PRICE_ERROR));
  });

  it("GetAssetPrices should fail if a price value is lower than zero", async () => {
    await chainlinkFeedRegistry.setPrice(underlyingToken.address, exactlyEnv.usdAddress, -10);

    await expect(
      exactlyOracle.getAssetsPrices(["ETH", "DAI"])
    ).to.be.revertedWith(errorGeneric(ProtocolError.PRICE_ERROR));
  });

  it("GetAssetPrice should fail when asset symbol is invalid", async () => {
    await expect(
      exactlyOracle.getAssetPrice("INVALID")
    ).to.be.reverted;
  });

  it("GetAssetPrices should fail if an asset symbol is invalid", async () => {
    await expect(
      exactlyOracle.getAssetsPrices(["ETH", "INVALID"])
    ).to.be.reverted;
  });

  it("SetAssetSources should set the address source of an asset", async () => {
    let linkSymbol = "LINK";
    let linkAddress = "0x514910771AF9Ca656af840dff83E8264EcF986CA";
    
    await exactlyOracle.setAssetSources([linkSymbol], [linkAddress]);
    await chainlinkFeedRegistry.setPrice(linkAddress, exactlyEnv.usdAddress, 10);
    await expect(exactlyOracle.getAssetPrice(linkSymbol)).to.not.be.reverted;
  });

  it("SetAssetSources should fail when called with different length for asset symbols and addresses", async () => {
    await expect(
      exactlyOracle.setAssetSources(["ETH", "BTC"], ["0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"])
    ).to.be.revertedWith(errorGeneric(ProtocolError.INCONSISTENT_PARAMS_LENGTH));
  });

  it("SetAssetSources should fail when called from third parties", async () => {
    await expect(
      exactlyOracle.connect(user).setAssetSources([], [])
    ).to.be.revertedWith("AccessControl");
  });

  it("GetSourceOfAssetBySymbol should get the source of an asset by its symbol", async () => {
    let sourceOfAsset = await exactlyOracle.getSourceOfAssetBySymbol("DAI");

    expect(sourceOfAsset).to.be.equal(underlyingToken.address);
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
