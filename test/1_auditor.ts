import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { Auditor, FixedLender, MockChainlinkFeedRegistry, MockToken, WETH } from "../types";
import futurePools from "./utils/futurePools";
import USD_ADDRESS from "./utils/USD_ADDRESS";

const {
  constants: { AddressZero },
  utils: { parseUnits },
  getUnnamedSigners,
  getNamedSigner,
  getContract,
} = ethers;

describe("Auditor from User Space", function () {
  let dai: MockToken;
  let weth: WETH;
  let auditor: Auditor;
  let feedRegistry: MockChainlinkFeedRegistry;
  let fixedLenderDAI: FixedLender;
  let fixedLenderWETH: FixedLender;

  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [user] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture(["Markets"]);

    dai = await getContract<MockToken>("DAI", user);
    weth = await getContract<WETH>("WETH", user);
    auditor = await getContract<Auditor>("Auditor", user);
    feedRegistry = await getContract<MockChainlinkFeedRegistry>("FeedRegistry", user);
    fixedLenderDAI = await getContract<FixedLender>("FixedLenderDAI", user);
    fixedLenderWETH = await getContract<FixedLender>("FixedLenderWETH", user);

    await dai.connect(owner).transfer(user.address, parseUnits("100000"));
    await weth.deposit({ value: parseUnits("10") });
    await weth.approve(fixedLenderWETH.address, parseUnits("10"));
  });

  it("We enter market twice without failing", async () => {
    await auditor.enterMarket(fixedLenderDAI.address);
    await expect(auditor.enterMarket(fixedLenderDAI.address)).to.not.be.reverted.and.to.not.emit(
      auditor,
      "MarketEntered",
    );
  });

  it("We enter WETH market (market index 1) twice without failing", async () => {
    await auditor.enterMarket(fixedLenderWETH.address);
    await expect(auditor.enterMarket(fixedLenderWETH.address)).to.not.be.reverted.and.to.not.emit(
      auditor,
      "MarketEntered",
    );
  });

  it("EnterMarket should emit event", async () => {
    await expect(auditor.enterMarket(fixedLenderDAI.address))
      .to.emit(auditor, "MarketEntered")
      .withArgs(fixedLenderDAI.address, user.address);
  });

  it("ExitMarket should emit event", async () => {
    await auditor.enterMarket(fixedLenderDAI.address);
    await expect(auditor.exitMarket(fixedLenderDAI.address))
      .to.emit(auditor, "MarketExited")
      .withArgs(fixedLenderDAI.address, user.address);
  });

  it("validateBorrowMP should fail for when oracle gets weird", async () => {
    await dai.approve(fixedLenderDAI.address, 666);
    await fixedLenderDAI.deposit(666, user.address);
    await auditor.enterMarket(fixedLenderDAI.address);
    await feedRegistry.setPrice(dai.address, USD_ADDRESS, 0);
    await expect(
      fixedLenderDAI.borrowAtMaturity(futurePools(1)[0], 1, 1, user.address, user.address),
    ).to.be.revertedWith("InvalidPrice()");
  });

  it("SeizeAllowed should fail when liquidator is borrower", async () => {
    await expect(
      auditor.seizeAllowed(fixedLenderDAI.address, fixedLenderDAI.address, owner.address, owner.address),
    ).to.be.revertedWith("LiquidatorNotBorrower()");
  });

  it("LiquidateAllowed should revert with INSUFFICIENT_SHORTFALL if user has no shortfall", async () => {
    await expect(
      auditor.liquidateAllowed(fixedLenderDAI.address, fixedLenderDAI.address, owner.address, user.address),
    ).to.be.revertedWith("InsufficientShortfall()"); // Any failure except MARKET_NOT_LISTED
  });

  it("Auto-adding a market should only be allowed from a fixedLender", async () => {
    // we supply Dai to the protocol
    await dai.approve(fixedLenderDAI.address, 100);
    await fixedLenderDAI.deposit(100, user.address);

    // we make it count as collateral (DAI)
    await expect(auditor.validateBorrowMP(fixedLenderDAI.address, owner.address)).to.be.revertedWith(
      "NotFixedLender()",
    );
  });

  it("LiquidateCalculateSeizeAmount should fail when oracle is acting weird", async () => {
    await feedRegistry.setPrice(dai.address, USD_ADDRESS, 0);
    await expect(
      auditor.liquidateCalculateSeizeAmount(fixedLenderDAI.address, fixedLenderDAI.address, 100),
    ).to.be.revertedWith("InvalidPrice()");
  });

  it("we deposit dai & eth to the protocol and we use them both for collateral to take a loan", async () => {
    // we supply Dai to the protocol
    const amountDAI = parseUnits("100");
    await dai.approve(fixedLenderDAI.address, amountDAI);
    await fixedLenderDAI.deposit(amountDAI, user.address);
    expect(await dai.balanceOf(fixedLenderDAI.address)).to.equal(amountDAI);
    // we make it count as collateral (DAI)
    await auditor.enterMarket(fixedLenderDAI.address);

    // we supply ETH to the protocol
    const amountETH = parseUnits("1");
    await fixedLenderWETH.deposit(amountETH, user.address);
    expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(amountETH);
    // we make it count as collateral (WETH)
    await auditor.enterMarket(fixedLenderWETH.address);

    const [collateral] = await auditor.accountLiquidity(user.address, AddressZero, 0);
    const { adjustFactor: adjustFactorDAI } = await auditor.markets(fixedLenderDAI.address);
    const { adjustFactor: adjustFactorWETH } = await auditor.markets(fixedLenderWETH.address);
    const collateralDAI = amountDAI.mul(adjustFactorDAI).div(parseUnits("1"));
    const collateralETH = amountETH.mul(adjustFactorWETH).div(parseUnits("1")).mul(1_000);
    expect(collateral).to.equal(collateralDAI.add(collateralETH));
  });

  it("Contract's state variable accountMarkets should correctly add and remove the asset which the user entered and exited as collateral", async () => {
    await auditor.enterMarket(fixedLenderDAI.address);
    await auditor.enterMarket(fixedLenderWETH.address);

    await expect(auditor.exitMarket(fixedLenderDAI.address)).to.not.be.reverted;
    await expect(auditor.exitMarket(fixedLenderWETH.address)).to.not.be.reverted;
  });

  it("Auditor reverts if Oracle acts weird", async () => {
    // we supply Dai to the protocol
    await dai.approve(fixedLenderDAI.address, 100);
    await fixedLenderDAI.depositAtMaturity(futurePools(1)[0], 100, 100, user.address);
    // we make it count as collateral (DAI)
    await auditor.enterMarket(fixedLenderDAI.address);
    await feedRegistry.setPrice(dai.address, USD_ADDRESS, 0);
    await expect(auditor.accountLiquidity(user.address, AddressZero, 0)).to.revertedWith("InvalidPrice()");
  });

  it("Get data from correct market", async () => {
    const { symbol, name, isListed, adjustFactor, decimals } = await auditor.markets(fixedLenderDAI.address);

    expect(adjustFactor).to.equal(parseUnits("0.8"));
    expect(symbol).to.equal("DAI");
    expect(name).to.equal("DAI");
    expect(isListed).to.equal(true);
    expect(decimals).to.equal(18);
  });
});
