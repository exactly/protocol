import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { Auditor, ETHFixedLender, FixedLender, MockedChainlinkFeedRegistry, MockedToken, WETH9 } from "../types";
import GenericError, { ErrorCode } from "./utils/GenericError";
import timelockExecute from "./utils/timelockExecute";
import futurePools from "./utils/futurePools";
import USD_ADDRESS from "./utils/USD_ADDRESS";

const {
  utils: { parseUnits },
  getUnnamedSigners,
  getNamedSigner,
  getContract,
} = ethers;

describe("Auditor from User Space", function () {
  let dai: MockedToken;
  let weth: WETH9;
  let auditor: Auditor;
  let feedRegistry: MockedChainlinkFeedRegistry;
  let fixedLenderDAI: FixedLender;
  let fixedLenderWETH: ETHFixedLender;

  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [user] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture(["Markets"]);

    dai = await getContract<MockedToken>("DAI", user);
    weth = await getContract<WETH9>("WETH", user);
    auditor = await getContract<Auditor>("Auditor", user);
    feedRegistry = await getContract<MockedChainlinkFeedRegistry>("FeedRegistry", user);
    fixedLenderDAI = await getContract<FixedLender>("FixedLenderDAI", user);
    fixedLenderWETH = await getContract<ETHFixedLender>("FixedLenderWETH", user);

    await dai.connect(owner).transfer(user.address, parseUnits("100000"));
  });

  it("We enter market twice without failing", async () => {
    await auditor.enterMarkets([fixedLenderDAI.address]);
    await expect(auditor.enterMarkets([fixedLenderDAI.address])).to.not.be.reverted.and.to.not.emit(
      auditor,
      "MarketEntered",
    );
  });

  it("EnterMarkets should emit event", async () => {
    await expect(auditor.enterMarkets([fixedLenderDAI.address]))
      .to.emit(auditor, "MarketEntered")
      .withArgs(fixedLenderDAI.address, user.address);
  });

  it("ExitMarket should emit event", async () => {
    await auditor.enterMarkets([fixedLenderDAI.address]);
    await expect(auditor.exitMarket(fixedLenderDAI.address))
      .to.emit(auditor, "MarketExited")
      .withArgs(fixedLenderDAI.address, user.address);
  });

  it("validateBorrowMP should fail for when oracle gets weird", async () => {
    await dai.approve(fixedLenderDAI.address, 666);
    await fixedLenderDAI.depositToSmartPool(666);
    await auditor.enterMarkets([fixedLenderDAI.address]);
    await feedRegistry.setPrice(dai.address, USD_ADDRESS, 0);
    await expect(fixedLenderDAI.borrowFromMaturityPool(1, futurePools(1)[0], 1)).to.be.revertedWith(
      GenericError(ErrorCode.PRICE_ERROR),
    );
  });

  it("SeizeAllowed should fail when liquidator is borrower", async () => {
    await expect(
      auditor.seizeAllowed(fixedLenderDAI.address, fixedLenderDAI.address, owner.address, owner.address),
    ).to.be.revertedWith(GenericError(ErrorCode.LIQUIDATOR_NOT_BORROWER));
  });

  it("LiquidateAllowed should revert with INSUFFICIENT_SHORTFALL if user has no shortfall", async () => {
    await expect(
      auditor.liquidateAllowed(fixedLenderDAI.address, fixedLenderDAI.address, owner.address, user.address, 100),
    ).to.be.revertedWith(GenericError(ErrorCode.INSUFFICIENT_SHORTFALL)); // Any failure except MARKET_NOT_LISTED
  });

  it("Auto-adding a market should only be allowed from a fixedLender", async () => {
    // we supply Dai to the protocol
    await dai.approve(fixedLenderDAI.address, 100);
    await fixedLenderDAI.depositToSmartPool(100);

    // we make it count as collateral (DAI)
    await expect(auditor.validateBorrowMP(fixedLenderDAI.address, owner.address)).to.be.revertedWith(
      GenericError(ErrorCode.NOT_A_FIXED_LENDER_SENDER),
    );
  });

  it("SetBorrowCap should block borrowing more than the cap on a listed market", async () => {
    await timelockExecute(owner, auditor, "setMarketBorrowCaps", [[fixedLenderDAI.address], [10]]);
    await dai.approve(fixedLenderDAI.address, 1000);
    await fixedLenderDAI.depositToSmartPool(1000);
    await expect(
      // user tries to borrow more than the cap
      fixedLenderDAI.borrowFromMaturityPool(20, futurePools(1)[0], 22),
    ).to.be.revertedWith(GenericError(ErrorCode.MARKET_BORROW_CAP_REACHED));
  });

  it("LiquidateCalculateSeizeAmount should fail when oracle is acting weird", async () => {
    await feedRegistry.setPrice(dai.address, USD_ADDRESS, 0);
    await expect(
      auditor.liquidateCalculateSeizeAmount(fixedLenderDAI.address, fixedLenderDAI.address, 100),
    ).to.be.revertedWith(GenericError(ErrorCode.PRICE_ERROR));
  });

  it("Future pools should match JS generated ones", async () => {
    await timelockExecute(owner, fixedLenderDAI, "setMaxFuturePools", [24]);
    expect(await fixedLenderDAI.getFuturePools()).to.deep.equal(futurePools(24));
  });

  it("we deposit dai & eth to the protocol and we use them both for collateral to take a loan", async () => {
    // we supply Dai to the protocol
    const amountDAI = parseUnits("100");
    await dai.approve(fixedLenderDAI.address, amountDAI);
    await fixedLenderDAI.depositToSmartPool(amountDAI);
    expect(await dai.balanceOf(fixedLenderDAI.address)).to.equal(amountDAI);
    // we make it count as collateral (DAI)
    await auditor.enterMarkets([fixedLenderDAI.address]);

    // we supply Eth to the protocol
    const amountETH = parseUnits("1");
    await fixedLenderWETH.depositToSmartPoolEth({ value: amountETH });
    expect(await weth.balanceOf(fixedLenderWETH.address)).to.equal(amountETH);
    // we make it count as collateral (WETH)
    await auditor.enterMarkets([fixedLenderWETH.address]);

    const [liquidity] = await auditor.getAccountLiquidity(user.address);
    const [, , , collateralRateDAI] = await auditor.getMarketData(fixedLenderDAI.address);
    const [, , , collateralRateWETH] = await auditor.getMarketData(fixedLenderWETH.address);
    const collateralDAI = amountDAI.mul(collateralRateDAI).div(parseUnits("1"));
    const collateralETH = amountETH.mul(collateralRateWETH).div(parseUnits("1")).mul(1_000);
    expect(liquidity).to.equal(collateralDAI.add(collateralETH));
  });

  it("Contract's state variable accountAssets should correctly add and remove the asset which the user entered and exited as collateral", async () => {
    await auditor.enterMarkets([fixedLenderDAI.address, fixedLenderWETH.address]);

    await expect(auditor.exitMarket(fixedLenderDAI.address)).to.not.be.reverted;
    await expect(auditor.exitMarket(fixedLenderWETH.address)).to.not.be.reverted;
  });

  it("Auditor reverts if Oracle acts weird", async () => {
    // we supply Dai to the protocol
    await dai.approve(fixedLenderDAI.address, 100);
    await fixedLenderDAI.depositToMaturityPool(100, futurePools(1)[0], 100);
    // we make it count as collateral (DAI)
    await auditor.enterMarkets([fixedLenderDAI.address]);
    await feedRegistry.setPrice(dai.address, USD_ADDRESS, 0);
    await expect(auditor.getAccountLiquidity(user.address)).to.revertedWith(GenericError(ErrorCode.PRICE_ERROR));
  });

  it("Get data from correct market", async () => {
    const [symbol, name, isListed, collateralFactor, decimals] = await auditor.getMarketData(fixedLenderDAI.address);

    expect(collateralFactor).to.equal(parseUnits("0.8"));
    expect(symbol).to.equal("DAI");
    expect(name).to.equal("DAI");
    expect(isListed).to.equal(true);
    expect(decimals).to.equal(18);
  });

  it("Try to get data from wrong address", async () => {
    await expect(auditor.getMarketData(user.address)).to.be.revertedWith(GenericError(ErrorCode.MARKET_NOT_LISTED));
  });
});
