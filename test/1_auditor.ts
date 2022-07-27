import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { Auditor, Market, MockERC20, MockPriceFeed, WETH } from "../types";
import futurePools from "./utils/futurePools";

const {
  constants: { AddressZero, MaxUint256 },
  utils: { parseUnits },
  getUnnamedSigners,
  getNamedSigner,
  getContract,
} = ethers;

describe("Auditor from User Space", function () {
  let dai: MockERC20;
  let weth: WETH;
  let auditor: Auditor;
  let priceFeedDAI: MockPriceFeed;
  let marketDAI: Market;
  let marketWETH: Market;

  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [user] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture(["Markets"]);

    dai = await getContract<MockERC20>("DAI", user);
    weth = await getContract<WETH>("WETH", user);
    auditor = await getContract<Auditor>("Auditor", user);
    priceFeedDAI = await getContract<MockPriceFeed>("PriceFeedDAI", user);
    marketDAI = await getContract<Market>("MarketDAI", user);
    marketWETH = await getContract<Market>("MarketWETH", user);

    await dai.connect(owner).mint(user.address, parseUnits("100000"));
    await weth.deposit({ value: parseUnits("10") });
    await weth.approve(marketWETH.address, parseUnits("10"));
  });

  it("We enter market twice without failing", async () => {
    await auditor.enterMarket(marketDAI.address);
    await expect(auditor.enterMarket(marketDAI.address)).to.not.be.reverted.and.to.not.emit(auditor, "MarketEntered");
  });

  it("We enter WETH market (market index 1) twice without failing", async () => {
    await auditor.enterMarket(marketWETH.address);
    await expect(auditor.enterMarket(marketWETH.address)).to.not.be.reverted.and.to.not.emit(auditor, "MarketEntered");
  });

  it("EnterMarket should emit event", async () => {
    await expect(auditor.enterMarket(marketDAI.address))
      .to.emit(auditor, "MarketEntered")
      .withArgs(marketDAI.address, user.address);
  });

  it("ExitMarket should emit event", async () => {
    await auditor.enterMarket(marketDAI.address);
    await expect(auditor.exitMarket(marketDAI.address))
      .to.emit(auditor, "MarketExited")
      .withArgs(marketDAI.address, user.address);
  });

  it("checkBorrow should fail for when oracle gets weird", async () => {
    await dai.approve(marketDAI.address, 666);
    await marketDAI.deposit(666, user.address);
    await auditor.enterMarket(marketDAI.address);
    await priceFeedDAI.setPrice(0);
    await expect(marketDAI.borrowAtMaturity(futurePools(1)[0], 1, 1, user.address, user.address)).to.be.revertedWith(
      "InvalidPrice()",
    );
  });

  it("checkLiquidation should revert with INSUFFICIENT_SHORTFALL if user has no shortfall", async () => {
    await expect(
      auditor.checkLiquidation(marketDAI.address, marketDAI.address, user.address, MaxUint256),
    ).to.be.revertedWith("InsufficientShortfall()"); // Any failure except MARKET_NOT_LISTED
  });

  it("Auto-adding a market should only be allowed from a market", async () => {
    // we supply Dai to the protocol
    await dai.approve(marketDAI.address, 100);
    await marketDAI.deposit(100, user.address);

    // we make it count as collateral (DAI)
    await expect(auditor.checkBorrow(marketDAI.address, owner.address)).to.be.revertedWith("NotMarket()");
  });

  it("CalculateSeize should fail when oracle is acting weird", async () => {
    await priceFeedDAI.setPrice(0);
    await expect(auditor.calculateSeize(marketDAI.address, marketDAI.address, user.address, 100)).to.be.revertedWith(
      "0x00bfc921",
    );
  });

  it("we deposit dai & eth to the protocol and we use them both for collateral to take a loan", async () => {
    // we supply Dai to the protocol
    const amountDAI = parseUnits("100");
    await dai.approve(marketDAI.address, amountDAI);
    await marketDAI.deposit(amountDAI, user.address);
    expect(await dai.balanceOf(marketDAI.address)).to.equal(amountDAI);
    // we make it count as collateral (DAI)
    await auditor.enterMarket(marketDAI.address);

    // we supply ETH to the protocol
    const amountETH = parseUnits("1");
    await marketWETH.deposit(amountETH, user.address);
    expect(await weth.balanceOf(marketWETH.address)).to.equal(amountETH);
    // we make it count as collateral (WETH)
    await auditor.enterMarket(marketWETH.address);

    const [collateral] = await auditor.accountLiquidity(user.address, AddressZero, 0);
    const { adjustFactor: adjustFactorDAI } = await auditor.markets(marketDAI.address);
    const { adjustFactor: adjustFactorWETH } = await auditor.markets(marketWETH.address);
    const collateralDAI = amountDAI.mul(adjustFactorDAI).div(parseUnits("1"));
    const collateralETH = amountETH.mul(adjustFactorWETH).div(parseUnits("1")).mul(1_000);
    expect(collateral).to.equal(collateralDAI.add(collateralETH));
  });

  it("Contract's state variable accountMarkets should correctly add and remove the asset which the user entered and exited as collateral", async () => {
    await auditor.enterMarket(marketDAI.address);
    await auditor.enterMarket(marketWETH.address);

    await expect(auditor.exitMarket(marketDAI.address)).to.not.be.reverted;
    await expect(auditor.exitMarket(marketWETH.address)).to.not.be.reverted;
  });

  it("Auditor reverts if Oracle acts weird", async () => {
    // we supply Dai to the protocol
    await dai.approve(marketDAI.address, 100);
    await marketDAI.depositAtMaturity(futurePools(1)[0], 100, 100, user.address);
    // we make it count as collateral (DAI)
    await auditor.enterMarket(marketDAI.address);
    await priceFeedDAI.setPrice(0);
    await expect(auditor.accountLiquidity(user.address, AddressZero, 0)).to.revertedWith("0x00bfc921");
  });

  it("Get data from correct market", async () => {
    const { isListed, adjustFactor, decimals } = await auditor.markets(marketDAI.address);

    expect(adjustFactor).to.equal(parseUnits("0.8"));
    expect(isListed).to.equal(true);
    expect(decimals).to.equal(18);
  });
});
