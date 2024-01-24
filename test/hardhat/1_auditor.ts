import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { Auditor, Market, MockERC20, MockPriceFeed, WETH } from "../../types";
import timelockExecute from "./utils/timelockExecute";
import futurePools from "./utils/futurePools";

const { ZeroAddress, MaxUint256, parseUnits, getUnnamedSigners, getNamedSigner, getContract } = ethers;

describe("Auditor from Account Space", function () {
  let dai: MockERC20;
  let weth: WETH;
  let auditor: Auditor;
  let priceFeedDAI: MockPriceFeed;
  let marketDAI: Market;
  let marketWETH: Market;

  let owner: SignerWithAddress;
  let account: SignerWithAddress;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [account] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture("Markets");

    dai = await getContract<MockERC20>("DAI", account);
    weth = await getContract<WETH>("WETH", account);
    auditor = await getContract<Auditor>("Auditor", account);
    priceFeedDAI = await getContract<MockPriceFeed>("PriceFeedDAI", account);
    marketDAI = await getContract<Market>("MarketDAI", account);
    marketWETH = await getContract<Market>("MarketWETH", account);

    await timelockExecute(owner, auditor, "setAdjustFactor", [marketDAI.target, parseUnits("0.95")]);
    await dai.connect(owner).mint(account.address, parseUnits("100000"));
    await weth.deposit({ value: parseUnits("10") });
    await weth.approve(marketWETH.target, parseUnits("10"));
  });

  it("enters market twice without failing", async () => {
    await auditor.enterMarket(marketDAI.target);
    await expect(auditor.enterMarket(marketDAI.target)).to.not.emit(auditor, "MarketEntered");
  });

  it("enters WETH market (market index 1) twice without failing", async () => {
    await auditor.enterMarket(marketWETH.target);
    await expect(auditor.enterMarket(marketWETH.target)).to.not.emit(auditor, "MarketEntered");
  });

  it("EnterMarket should emit event", async () => {
    await expect(auditor.enterMarket(marketDAI.target))
      .to.emit(auditor, "MarketEntered")
      .withArgs(marketDAI.target, account.address);
  });

  it("ExitMarket should emit event", async () => {
    await auditor.enterMarket(marketDAI.target);
    await expect(auditor.exitMarket(marketDAI.target))
      .to.emit(auditor, "MarketExited")
      .withArgs(marketDAI.target, account.address);
  });

  it("checkBorrow should fail for when oracle gets weird", async () => {
    await dai.approve(marketDAI.target, 666);
    await marketDAI.deposit(666, account.address);
    await auditor.enterMarket(marketDAI.target);
    await priceFeedDAI.setPrice(0);
    await expect(
      marketDAI.borrowAtMaturity(futurePools(1)[0], 1, 1, account.address, account.address),
    ).to.be.revertedWithCustomError(auditor, "InvalidPrice");
  });

  it("checkLiquidation should revert with INSUFFICIENT_SHORTFALL if account has no shortfall", async () => {
    await expect(
      auditor.checkLiquidation(marketDAI.target, marketDAI.target, account.address, MaxUint256),
    ).to.be.revertedWithCustomError(auditor, "InsufficientShortfall"); // Any failure except MARKET_NOT_LISTED
  });

  it("Auto-adding a market should only be allowed from a market", async () => {
    // supply Dai to the protocol
    await dai.approve(marketDAI.target, 100);
    await marketDAI.deposit(100, account.address);

    // make it count as collateral (DAI)
    await expect(auditor.checkBorrow(marketDAI.target, owner.address)).to.be.revertedWithCustomError(
      auditor,
      "NotMarket",
    );
  });

  it("CalculateSeize should fail when oracle is acting weird", async () => {
    await priceFeedDAI.setPrice(0);
    await expect(
      auditor.calculateSeize(marketDAI.target, marketDAI.target, account.address, 100),
    ).to.be.revertedWithCustomError(auditor, "InvalidPrice");
  });

  it("deposits dai & eth to the protocol and uses them both for collateral to take a loan", async () => {
    // supply dai to the protocol
    const amountDAI = parseUnits("100");
    await dai.approve(marketDAI.target, amountDAI);
    await marketDAI.deposit(amountDAI, account.address);
    expect(await dai.balanceOf(marketDAI.target)).to.equal(amountDAI);
    // make it count as collateral (DAI)
    await auditor.enterMarket(marketDAI.target);

    // supply ETH to the protocol
    const amountETH = parseUnits("1");
    await marketWETH.deposit(amountETH, account.address);
    expect(await weth.balanceOf(marketWETH.target)).to.equal(amountETH);
    // make it count as collateral (WETH)
    await auditor.enterMarket(marketWETH.target);

    const [collateral] = await auditor.accountLiquidity(account.address, ZeroAddress, 0);
    const { adjustFactor: adjustFactorDAI } = await auditor.markets(marketDAI.target);
    const { adjustFactor: adjustFactorWETH } = await auditor.markets(marketWETH.target);
    const collateralDAI = (amountDAI * adjustFactorDAI) / parseUnits("1");
    const collateralETH = ((amountETH * adjustFactorWETH) / parseUnits("1")) * 1_000n;
    expect(collateral).to.equal(collateralDAI + collateralETH);
  });

  it("Contract's state variable accountMarkets should correctly add and remove the asset which the account entered and exited as collateral", async () => {
    await auditor.enterMarket(marketDAI.target);
    await auditor.enterMarket(marketWETH.target);

    await expect(auditor.exitMarket(marketDAI.target)).to.not.be.reverted;
    await expect(auditor.exitMarket(marketWETH.target)).to.not.be.reverted;
  });

  it("Auditor reverts if Oracle acts weird", async () => {
    // supply Dai to the protocol
    await dai.approve(marketDAI.target, 100);
    await marketDAI.depositAtMaturity(futurePools(1)[0], 100, 100, account.address);
    // make it count as collateral (DAI)
    await auditor.enterMarket(marketDAI.target);
    await priceFeedDAI.setPrice(0);
    await expect(auditor.accountLiquidity(account.address, ZeroAddress, 0)).to.revertedWithCustomError(
      auditor,
      "InvalidPrice",
    );
  });

  it("Get data from correct market", async () => {
    const { isListed, adjustFactor, decimals } = await auditor.markets(marketDAI.target);

    expect(adjustFactor).to.equal(parseUnits("0.95"));
    expect(isListed).to.equal(true);
    expect(decimals).to.equal(18);
  });
});
