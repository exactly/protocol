import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { MockPriceFeed, Auditor, Market } from "../../types";
import timelockExecute from "./utils/timelockExecute";

const { getUnnamedSigners, getNamedSigner, getContract } = ethers;

describe("auditor", function () {
  let auditor: Auditor;
  let priceFeedWETH: MockPriceFeed;
  let priceFeedDAI: MockPriceFeed;
  let marketDAI: Market;

  let account: SignerWithAddress;
  let owner: SignerWithAddress;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [account] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture("Markets");

    auditor = await getContract<Auditor>("Auditor", account);
    priceFeedDAI = await getContract<MockPriceFeed>("PriceFeedDAI", account);
    marketDAI = await getContract<Market>("MarketDAI", account);
    priceFeedWETH = await getContract<MockPriceFeed>("PriceFeedWETH", account);
  });

  it("GetAssetPrice returns a positive and valid price value", async () => {
    // The price returned by the oracle is previously scaled to an 18-digit decimal
    expect(await auditor.assetPrice(priceFeedDAI.address)).to.equal(10n ** 18n);
    expect(await auditor.assetPrice(priceFeedWETH.address)).to.equal(1_000n * 10n ** 18n);
  });

  it("GetAssetPrice should fail when price value is zero", async () => {
    await priceFeedDAI.setPrice(0);
    await expect(auditor.assetPrice(priceFeedDAI.address)).to.be.revertedWithCustomError(auditor, "InvalidPrice");
  });

  it("GetAssetPrice should fail when price value is lower than zero", async () => {
    await priceFeedDAI.setPrice(-10);
    await expect(auditor.assetPrice(priceFeedDAI.address)).to.be.revertedWithCustomError(auditor, "InvalidPrice");
  });

  it("GetAssetPrice should fail when asset address is invalid", async () => {
    await expect(auditor.assetPrice(account.address)).to.be.revertedWithoutReason();
  });

  it("SetPriceFeed should set the address source of an asset", async () => {
    await timelockExecute(owner, auditor, "grantRole", [await auditor.DEFAULT_ADMIN_ROLE(), owner.address]);
    const { address } = await deployments.deploy("NewPriceFeed", {
      contract: "MockPriceFeed",
      args: [8, 1],
      from: owner.address,
    });
    await expect(await auditor.connect(owner).setPriceFeed(marketDAI.address, address))
      .to.emit(auditor, "PriceFeedSet")
      .withArgs(marketDAI.address, address);
    await priceFeedDAI.setPrice(1);
    expect(await auditor.assetPrice(priceFeedDAI.address)).to.equal(1e10);
  });
});
