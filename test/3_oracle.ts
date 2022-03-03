import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { ExactlyOracle, MockedChainlinkFeedRegistry, MockedToken } from "../types";
import GenericError, { ErrorCode } from "./utils/GenericError";
import timelockExecute from "./utils/timelockExecute";
import USD_ADDRESS from "./utils/USD_ADDRESS";

const {
  utils: { parseUnits },
  getUnnamedSigners,
  getNamedSigner,
  getContract,
  provider,
} = ethers;

describe("ExactlyOracle", function () {
  let dai: MockedToken;
  let feedRegistry: MockedChainlinkFeedRegistry;
  let exactlyOracle: ExactlyOracle;

  let user: SignerWithAddress;
  let owner: SignerWithAddress;
  let timestamp: number;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [user] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture(["Markets"]);

    dai = await getContract<MockedToken>("DAI", user);
    feedRegistry = await getContract<MockedChainlinkFeedRegistry>("FeedRegistry", user);
    exactlyOracle = await getContract<ExactlyOracle>("ExactlyOracle", user);

    await dai.connect(owner).transfer(user.address, parseUnits("100000"));
    timestamp = Math.floor(Date.now() / 1_000) + 1_000;
  });

  it("GetAssetPrice returns a positive and valid price value", async () => {
    // The price returned by the oracle is previously scaled to an 18-digit decimal
    expect(await exactlyOracle.getAssetPrice("DAI")).to.equal(10n ** 18n);
    expect(await exactlyOracle.getAssetPrice("WETH")).to.equal(1_000n * 10n ** 18n);
  });

  it("GetAssetPrice does not fail when Chainlink price is not older than maxDelayTime", async () => {
    await feedRegistry.setUpdatedAtTimestamp(timestamp - (86_400 - 1));
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await provider.send("evm_mine", []);
    await expect(exactlyOracle.getAssetPrice("DAI")).to.not.be.reverted;
  });

  it("GetAssetPrice does not fail when Chainlink price is equal to maxDelayTime", async () => {
    await feedRegistry.setUpdatedAtTimestamp(timestamp - 86_400);
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await provider.send("evm_mine", []);
    await expect(exactlyOracle.getAssetPrice("DAI")).to.not.be.reverted;
  });

  it("GetAssetPrice should fail when Chainlink price is older than maxDelayTime", async () => {
    await feedRegistry.setUpdatedAtTimestamp(timestamp - (86_400 + 1));
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await provider.send("evm_mine", []);
    await expect(exactlyOracle.getAssetPrice("DAI")).to.be.revertedWith(GenericError(ErrorCode.PRICE_ERROR));
  });

  it("GetAssetPrice should fail when price value is zero", async () => {
    await feedRegistry.setPrice(dai.address, USD_ADDRESS, 0);
    await expect(exactlyOracle.getAssetPrice("DAI")).to.be.revertedWith(GenericError(ErrorCode.PRICE_ERROR));
  });

  it("GetAssetPrice should fail when price value is lower than zero", async () => {
    await feedRegistry.setPrice(dai.address, USD_ADDRESS, -10);
    await expect(exactlyOracle.getAssetPrice("DAI")).to.be.revertedWith(GenericError(ErrorCode.PRICE_ERROR));
  });

  it("GetAssetPrice should fail when asset symbol is invalid", async () => {
    await expect(exactlyOracle.getAssetPrice("INVALID")).to.be.revertedWith(GenericError(ErrorCode.PRICE_ERROR));
  });

  it("SetAssetSources should set the address source of an asset", async () => {
    const linkSymbol = "LINK";
    const linkAddress = "0x514910771AF9Ca656af840dff83E8264EcF986CA";
    await timelockExecute(owner, exactlyOracle, "grantRole", [await exactlyOracle.DEFAULT_ADMIN_ROLE(), owner.address]);
    await expect(await exactlyOracle.connect(owner).setAssetSources([linkSymbol], [linkAddress]))
      .to.emit(exactlyOracle, "SymbolSourceUpdated")
      .withArgs(linkSymbol, linkAddress);
    await feedRegistry.setPrice(linkAddress, USD_ADDRESS, 1);
    await feedRegistry.setUpdatedAtTimestamp(timestamp - 86_400);
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await provider.send("evm_mine", []);
    expect(await exactlyOracle.getAssetPrice(linkSymbol)).to.equal(1e10);
  });

  it("SetAssetSources should fail when called with different length for asset symbols and addresses", async () => {
    await timelockExecute(owner, exactlyOracle, "grantRole", [await exactlyOracle.DEFAULT_ADMIN_ROLE(), owner.address]);
    await expect(
      exactlyOracle.connect(owner).setAssetSources(["WETH", "BTC"], ["0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"]),
    ).to.be.revertedWith(GenericError(ErrorCode.INCONSISTENT_PARAMS_LENGTH));
  });

  it("SetAssetSources should fail when called from third parties", async () => {
    await expect(exactlyOracle.setAssetSources([], [])).to.be.revertedWith("AccessControl");
  });
});
