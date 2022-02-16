import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { errorGeneric, ExaTime, ProtocolError } from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv } from "./defaultEnv";

describe("ExactlyOracle", function () {
  let exactlyEnv: DefaultEnv;

  let exactlyOracle: Contract;
  let chainlinkFeedRegistry: Contract;
  let underlyingToken: Contract;

  let user: SignerWithAddress;
  let snapshot: any;
  let exaTime = new ExaTime();
  let mockedDate = exaTime.timestamp;
  let maxDelayTime: number;

  // Set the MockedOracle prices to zero
  let mockedTokens = new Map([
    [
      "DAI",
      {
        decimals: 18,
        collateralRate: parseUnits("0.8"),
        usdPrice: parseUnits("0"),
      },
    ],
    [
      "WETH",
      {
        decimals: 18,
        collateralRate: parseUnits("0.7"),
        usdPrice: parseUnits("0"),
      },
    ],
  ]);
  let chainlinkPrices = new Map([
    ["DAI", { usdPrice: parseUnits("1", 8) }],
    ["WETH", { usdPrice: parseUnits("3100", 8) }],
  ]);

  before(async () => {
    [, user] = await ethers.getSigners();
    exactlyEnv = await DefaultEnv.create({ mockedTokens });
    underlyingToken = exactlyEnv.getUnderlying("DAI");
    const ChainlinkFeedRegistryMock = await ethers.getContractFactory(
      "MockedChainlinkFeedRegistry"
    );
    chainlinkFeedRegistry = await ChainlinkFeedRegistryMock.deploy();
    await chainlinkFeedRegistry.deployed();

    let tokenAddresses = new Array();
    let tokenNames = new Array();
    await Promise.all(
      Array.from(chainlinkPrices.keys()).map(async (tokenName) => {
        const token = exactlyEnv.getUnderlying(tokenName);
        const { usdPrice } = chainlinkPrices.get(tokenName)!;
        tokenAddresses.push(token.address);
        tokenNames.push(tokenName);

        await chainlinkFeedRegistry.setPrice(
          token.address,
          exactlyEnv.usdAddress,
          usdPrice
        );
      })
    );
    await chainlinkFeedRegistry.setUpdatedAtTimestamp(exaTime.timestamp);

    const ExactlyOracle = await ethers.getContractFactory("ExactlyOracle");
    exactlyOracle = await ExactlyOracle.deploy(
      chainlinkFeedRegistry.address,
      tokenNames,
      tokenAddresses,
      exactlyEnv.usdAddress,
      exactlyEnv.maxOracleDelayTime
    );
    await exactlyOracle.deployed();
    await exactlyOracle.setAssetSources(tokenNames, tokenAddresses);
    await exactlyEnv.setOracle(exactlyOracle.address);
    maxDelayTime = await exactlyOracle.maxDelayTime();

    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    mockedDate += exaTime.ONE_DAY; // we add a day so it's not the same timestamp than previous blocks
  });

  it("GetAssetPrice returns a positive and valid price value", async () => {
    let priceOfEth = await exactlyOracle.getAssetPrice("WETH");
    let priceOfDai = await exactlyOracle.getAssetPrice("DAI");

    // The price returned by the oracle is previously scaled to an 18-digit decimal
    expect(priceOfEth).to.be.equal(
      chainlinkPrices.get("WETH")!.usdPrice.mul(1e10)
    );
    expect(priceOfDai).to.be.equal(
      chainlinkPrices.get("DAI")!.usdPrice.mul(1e10)
    );
  });

  it("GetAssetPrice does not fail when Chainlink price is not older than maxDelayTime", async () => {
    await chainlinkFeedRegistry.setUpdatedAtTimestamp(
      mockedDate - (maxDelayTime - 1)
    );

    await exactlyEnv.moveInTime(mockedDate);
    await ethers.provider.send("evm_mine", []);

    await expect(exactlyOracle.getAssetPrice("DAI")).to.not.be.reverted;
  });

  it("GetAssetPrice does not fail when Chainlink price is equal to maxDelayTime", async () => {
    await chainlinkFeedRegistry.setUpdatedAtTimestamp(
      mockedDate - maxDelayTime
    );

    await exactlyEnv.moveInTime(mockedDate);
    await ethers.provider.send("evm_mine", []);

    await expect(exactlyOracle.getAssetPrice("DAI")).to.not.be.reverted;
  });

  it("GetAssetPrice should fail when Chainlink price is older than maxDelayTime", async () => {
    await chainlinkFeedRegistry.setUpdatedAtTimestamp(
      mockedDate - (maxDelayTime + 1)
    );

    await exactlyEnv.moveInTime(mockedDate);
    await ethers.provider.send("evm_mine", []);

    await expect(exactlyOracle.getAssetPrice("DAI")).to.be.revertedWith(
      errorGeneric(ProtocolError.PRICE_ERROR)
    );
  });

  it("GetAssetPrice should fail when price value is zero", async () => {
    await chainlinkFeedRegistry.setPrice(
      underlyingToken.address,
      exactlyEnv.usdAddress,
      0
    );

    await expect(exactlyOracle.getAssetPrice("DAI")).to.be.revertedWith(
      errorGeneric(ProtocolError.PRICE_ERROR)
    );
  });

  it("GetAssetPrice should fail when price value is lower than zero", async () => {
    await chainlinkFeedRegistry.setPrice(
      underlyingToken.address,
      exactlyEnv.usdAddress,
      -10
    );

    await expect(exactlyOracle.getAssetPrice("DAI")).to.be.revertedWith(
      errorGeneric(ProtocolError.PRICE_ERROR)
    );
  });

  it("GetAssetPrice should fail when asset symbol is invalid", async () => {
    await expect(exactlyOracle.getAssetPrice("INVALID")).to.be.revertedWith(
      errorGeneric(ProtocolError.PRICE_ERROR)
    );
  });

  it("SetAssetSources should set the address source of an asset", async () => {
    let linkSymbol = "LINK";
    let linkAddress = "0x514910771AF9Ca656af840dff83E8264EcF986CA";

    await expect(
      await exactlyOracle.setAssetSources([linkSymbol], [linkAddress])
    )
      .to.emit(exactlyOracle, "SymbolSourceUpdated")
      .withArgs(linkSymbol, linkAddress);
    await chainlinkFeedRegistry.setPrice(
      linkAddress,
      exactlyEnv.usdAddress,
      10
    );

    await chainlinkFeedRegistry.setUpdatedAtTimestamp(
      mockedDate - maxDelayTime
    );
    await exactlyEnv.moveInTime(mockedDate);
    await ethers.provider.send("evm_mine", []);

    await expect(exactlyOracle.getAssetPrice(linkSymbol)).to.not.be.reverted;
  });

  it("SetAssetSources should fail when called with different length for asset symbols and addresses", async () => {
    await expect(
      exactlyOracle.setAssetSources(
        ["WETH", "BTC"],
        ["0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"]
      )
    ).to.be.revertedWith(
      errorGeneric(ProtocolError.INCONSISTENT_PARAMS_LENGTH)
    );
  });

  it("SetAssetSources should fail when called from third parties", async () => {
    await expect(
      exactlyOracle.connect(user).setAssetSources([], [])
    ).to.be.revertedWith("AccessControl");
  });

  after(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
