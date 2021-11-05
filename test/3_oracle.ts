import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import {
  errorGeneric,
  ExactlyEnv,
  ProtocolError,
  DefaultEnv,
} from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("ExactlyOracle", function () {
  let exactlyEnv: DefaultEnv;

  let exactlyOracle: Contract;
  let chainlinkFeedRegistry: Contract;
  let underlyingToken: Contract;

  let user: SignerWithAddress;
  let snapshot: any;

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
      "ETH",
      {
        decimals: 18,
        collateralRate: parseUnits("0.7"),
        usdPrice: parseUnits("0"),
      },
    ],
  ]);
  let chainlinkPrices = new Map([
    ["DAI", { usdPrice: parseUnits("1", 8) }],
    ["ETH", { usdPrice: parseUnits("3100", 8) }],
  ]);

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });
  const MOCKED_DATE = Math.floor(Date.now() / 1000) + 3600; // we add a day so it's not the same timestamp of previous blocks

  beforeEach(async () => {
    [, user] = await ethers.getSigners();
    exactlyEnv = await ExactlyEnv.create(mockedTokens);
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
    await chainlinkFeedRegistry.setUpdatedAtTimestamp(Math.floor(Date.now() / 1000));

    const ExactlyOracle = await ethers.getContractFactory("ExactlyOracle");
    exactlyOracle = await ExactlyOracle.deploy(
      chainlinkFeedRegistry.address,
      tokenNames,
      tokenAddresses,
      exactlyEnv.usdAddress
    );
    await exactlyOracle.deployed();
    await exactlyOracle.setAssetSources(tokenNames, tokenAddresses);
    await exactlyEnv.setOracle(exactlyOracle.address);

    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  it("GetAssetPrice returns a positive and valid price value", async () => {
    let priceOfEth = await exactlyOracle.getAssetPrice("ETH");
    let priceOfDai = await exactlyOracle.getAssetPrice("DAI");

    // The price returned by the oracle is previously scaled to an 18-digit decimal
    expect(priceOfEth).to.be.equal(
      chainlinkPrices.get("ETH")!.usdPrice.mul(1e10)
    );
    expect(priceOfDai).to.be.equal(
      chainlinkPrices.get("DAI")!.usdPrice.mul(1e10)
    );
  });

  it("GetAssetPrice does not fail when updatedAt time is equal to maxDelayTime", async () => {
    let maxDelayTime = await exactlyOracle.MAX_DELAY_TIME();
    await chainlinkFeedRegistry.setUpdatedAtTimestamp(MOCKED_DATE - (maxDelayTime));

    await ethers.provider.send("evm_setNextBlockTimestamp", [
      MOCKED_DATE
    ]);
    await ethers.provider.send("evm_mine", []);

    await expect(
      exactlyOracle.getAssetPrice("DAI")
    ).to.not.be.reverted;
  });

  it("GetAssetPrice does not fail when updatedAt time is above maxDelayTime (price updated)", async () => {
    let maxDelayTime = await exactlyOracle.MAX_DELAY_TIME();
    await chainlinkFeedRegistry.setUpdatedAtTimestamp(MOCKED_DATE - (maxDelayTime - 1));

    await ethers.provider.send("evm_setNextBlockTimestamp", [
      MOCKED_DATE
    ]);
    await ethers.provider.send("evm_mine", []);

    await expect(
      exactlyOracle.getAssetPrice("DAI")
    ).to.not.be.reverted;
  });

  it("GetAssetPrice does not fail when updatedAt time is equal to maxDelayTime (price updated)", async () => {
    let maxDelayTime = await exactlyOracle.MAX_DELAY_TIME();
    await chainlinkFeedRegistry.setUpdatedAtTimestamp(MOCKED_DATE - (maxDelayTime));

    await ethers.provider.send("evm_setNextBlockTimestamp", [
      MOCKED_DATE
    ]);
    await ethers.provider.send("evm_mine", []);

    await expect(
      exactlyOracle.getAssetPrice("DAI")
    ).to.not.be.reverted;
  });

  it("GetAssetPrice should fail when updatedAt time is below maxDelayTime (price outdated)", async () => {
    let maxDelayTime = await exactlyOracle.MAX_DELAY_TIME();
    await chainlinkFeedRegistry.setUpdatedAtTimestamp(MOCKED_DATE - (maxDelayTime + 1));

    await ethers.provider.send("evm_setNextBlockTimestamp", [
      MOCKED_DATE
    ]);
    await ethers.provider.send("evm_mine", []);

    await expect(
      exactlyOracle.getAssetPrice("DAI")
    ).to.be.revertedWith(errorGeneric(ProtocolError.PRICE_ERROR));
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
    ).to.emit(exactlyOracle, "SymbolSourceUpdated").withArgs(linkSymbol, linkAddress);
    await chainlinkFeedRegistry.setPrice(linkAddress, exactlyEnv.usdAddress, 10);
    await expect(exactlyOracle.getAssetPrice(linkSymbol)).to.not.be.reverted;
  });

  it("SetAssetSources should fail when called with different length for asset symbols and addresses", async () => {
    await expect(
      exactlyOracle.setAssetSources(
        ["ETH", "BTC"],
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

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
