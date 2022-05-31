import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { ExactlyOracle, MockChainlinkFeedRegistry, MockToken, FixedLender } from "../types";
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
  let dai: MockToken;
  let feedRegistry: MockChainlinkFeedRegistry;
  let exactlyOracle: ExactlyOracle;
  let fixedLenderDAI: FixedLender;
  let fixedLenderWETH: FixedLender;

  let user: SignerWithAddress;
  let owner: SignerWithAddress;
  let timestamp: number;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [user] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture(["Markets"]);

    dai = await getContract<MockToken>("DAI", user);
    feedRegistry = await getContract<MockChainlinkFeedRegistry>("FeedRegistry", user);
    exactlyOracle = await getContract<ExactlyOracle>("ExactlyOracle", user);
    fixedLenderDAI = await getContract<FixedLender>("FixedLenderDAI", user);
    fixedLenderWETH = await getContract<FixedLender>("FixedLenderWETH", user);

    await dai.connect(owner).transfer(user.address, parseUnits("100000"));
    timestamp = Math.floor(Date.now() / 1_000) + 1_000;
  });

  it("GetAssetPrice returns a positive and valid price value", async () => {
    // The price returned by the oracle is previously scaled to an 18-digit decimal
    expect(await exactlyOracle.getAssetPrice(fixedLenderDAI.address)).to.equal(10n ** 18n);
    expect(await exactlyOracle.getAssetPrice(fixedLenderWETH.address)).to.equal(1_000n * 10n ** 18n);
  });

  it("GetAssetPrice does not fail when Chainlink price is not older than maxDelayTime", async () => {
    await feedRegistry.setUpdatedAtTimestamp(timestamp - (86_400 - 1));
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await provider.send("evm_mine", []);
    await expect(exactlyOracle.getAssetPrice(fixedLenderDAI.address)).to.not.be.reverted;
  });

  it("GetAssetPrice does not fail when Chainlink price is equal to maxDelayTime", async () => {
    await feedRegistry.setUpdatedAtTimestamp(timestamp - 86_400);
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await provider.send("evm_mine", []);
    await expect(exactlyOracle.getAssetPrice(fixedLenderDAI.address)).to.not.be.reverted;
  });

  it("GetAssetPrice should fail when Chainlink price is older than maxDelayTime", async () => {
    await feedRegistry.setUpdatedAtTimestamp(timestamp - (86_400 + 1));
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await provider.send("evm_mine", []);
    await expect(exactlyOracle.getAssetPrice(fixedLenderDAI.address)).to.be.revertedWith("InvalidPrice()");
  });

  it("GetAssetPrice should fail when price value is zero", async () => {
    await feedRegistry.setPrice(dai.address, USD_ADDRESS, 0);
    await expect(exactlyOracle.getAssetPrice(fixedLenderDAI.address)).to.be.revertedWith("InvalidPrice()");
  });

  it("GetAssetPrice should fail when price value is lower than zero", async () => {
    await feedRegistry.setPrice(dai.address, USD_ADDRESS, -10);
    await expect(exactlyOracle.getAssetPrice(fixedLenderDAI.address)).to.be.revertedWith("InvalidPrice()");
  });

  it("GetAssetPrice should fail when asset address is invalid", async () => {
    await expect(exactlyOracle.getAssetPrice(user.address)).to.be.revertedWith("InvalidPrice()");
  });

  it("SetAssetSource should set the address source of an asset", async () => {
    await timelockExecute(owner, exactlyOracle, "grantRole", [await exactlyOracle.DEFAULT_ADMIN_ROLE(), owner.address]);
    await expect(
      await exactlyOracle.connect(owner).setAssetSource(fixedLenderDAI.address, await fixedLenderDAI.asset()),
    )
      .to.emit(exactlyOracle, "AssetSourceUpdated")
      .withArgs(fixedLenderDAI.address, await fixedLenderDAI.asset());
    await feedRegistry.setPrice(await fixedLenderDAI.asset(), USD_ADDRESS, 1);
    await feedRegistry.setUpdatedAtTimestamp(timestamp - 86_400);
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await provider.send("evm_mine", []);
    expect(await exactlyOracle.getAssetPrice(fixedLenderDAI.address)).to.equal(1e10);
  });

  it("SetAssetSource should fail when called from third parties", async () => {
    await expect(exactlyOracle.setAssetSource(fixedLenderDAI.address, await fixedLenderDAI.asset())).to.be.revertedWith(
      "AccessControl",
    );
  });
});
