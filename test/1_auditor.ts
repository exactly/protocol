import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits, formatUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { BigNumber } from "@ethersproject/bignumber";
import {
  ProtocolError,
  ExactlyEnv,
  ExaTime,
  parseDepositToMaturityPoolEvent,
  errorGeneric,
  DefaultEnv,
  PoolState,
  errorUnmatchedPool,
} from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Auditor from User Space", function () {
  let auditor: Contract;
  let exactlyEnv: DefaultEnv;
  let nextPoolID: number;

  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  let mockedTokens = new Map([
    [
      "DAI",
      {
        decimals: 18,
        collateralRate: parseUnits("0.8"),
        usdPrice: parseUnits("1"),
      },
    ],
    [
      "ETH",
      {
        decimals: 18,
        collateralRate: parseUnits("0.7"),
        usdPrice: parseUnits("3000"),
      },
    ],
    [
      "WBTC",
      {
        decimals: 8,
        collateralRate: parseUnits("0.6"),
        usdPrice: parseUnits("63000"),
      },
    ],
  ]);

  let snapshot: any;

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);

    [owner, user] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(mockedTokens);
    auditor = exactlyEnv.auditor;
    nextPoolID = new ExaTime().nextPoolID();

    // From Owner to User
    await exactlyEnv
      .getUnderlying("DAI")
      .transfer(user.address, parseUnits("100000"));
  });

  it("We try to enter an unlisted market and fail", async () => {
    await expect(
      auditor.enterMarkets([exactlyEnv.notAnFixedLenderAddress], nextPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
  });

  it("We try to enter an invalid market and fail", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    await expect(
      auditor.enterMarkets([fixedLenderDAI.address], nextPoolID + 333)
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.INVALID, PoolState.VALID)
    );
  });

  it("We enter market twice without failing", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    await auditor.enterMarkets([fixedLenderDAI.address], nextPoolID);
    await expect(auditor.enterMarkets([fixedLenderDAI.address], nextPoolID)).to
      .not.be.reverted;
  });

  it("We try to exit an unlisted market and fail", async () => {
    await expect(
      auditor.exitMarket(exactlyEnv.notAnFixedLenderAddress, nextPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
  });

  it("We try to exit an invalid market", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    await expect(
      auditor.exitMarket(fixedLenderDAI.address, nextPoolID + 333)
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_POOL_ID));
  });

  it("We can't exit a market until maturity", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    const dai = exactlyEnv.getUnderlying("DAI");
    const amountDAI = parseUnits("100");
    await dai.approve(fixedLenderDAI.address, amountDAI);
    await fixedLenderDAI.depositToMaturityPool(amountDAI, nextPoolID);

    // we make it count as collateral (DAI)
    await auditor.enterMarkets([fixedLenderDAI.address], nextPoolID);
    // Move in time to maturity
    await expect(
      auditor.exitMarket(fixedLenderDAI.address, nextPoolID)
    ).to.be.revertedWith(
      errorUnmatchedPool(PoolState.VALID, PoolState.MATURED)
    );
  });

  it("We exit a market after maturity", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    const dai = exactlyEnv.getUnderlying("DAI");
    const amountDAI = parseUnits("100");
    await dai.approve(fixedLenderDAI.address, amountDAI);
    await fixedLenderDAI.depositToMaturityPool(amountDAI, nextPoolID);

    // we make it count as collateral (DAI)
    await auditor.enterMarkets([fixedLenderDAI.address], nextPoolID);
    // Move in time to maturity
    await ethers.provider.send("evm_setNextBlockTimestamp", [nextPoolID]);
    await ethers.provider.send("evm_mine", []);
    await expect(auditor.exitMarket(fixedLenderDAI.address, nextPoolID)).to.not
      .be.reverted;
  });

  it("shouldn't allow to leave a market if there's debt", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    const dai = exactlyEnv.getUnderlying("DAI");
    const amountDAI = parseUnits("100");
    await dai.approve(fixedLenderDAI.address, amountDAI);
    await fixedLenderDAI.depositToMaturityPool(amountDAI, nextPoolID);
    await fixedLenderDAI.borrow(amountDAI.div(2), nextPoolID);

    // we make it count as collateral (DAI)
    await auditor.enterMarkets([fixedLenderDAI.address], nextPoolID);
    // Move in time to maturity
    await ethers.provider.send("evm_setNextBlockTimestamp", [nextPoolID]);
    await ethers.provider.send("evm_mine", []);
    await expect(
      auditor.exitMarket(fixedLenderDAI.address, nextPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.EXIT_MARKET_BALANCE_OWED));
  });

  it("beforeSupplySmartPool should fail for an unlisted market", async () => {
    await expect(
      auditor.beforeSupplySmartPool(
        exactlyEnv.notAnFixedLenderAddress,
        owner.address
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
  });

  it("beforeWithdrawSmartPool should fail for an unlisted market", async () => {
    await expect(
      auditor.beforeWithdrawSmartPool(
        exactlyEnv.notAnFixedLenderAddress,
        owner.address
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
  });

  it("SupplyAllowed should fail for an unlisted market", async () => {
    await expect(
      auditor.supplyAllowed(
        exactlyEnv.notAnFixedLenderAddress,
        owner.address,
        nextPoolID
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
  });

  it("BorrowAllowed should fail for an unlisted market", async () => {
    await expect(
      auditor.borrowAllowed(
        exactlyEnv.notAnFixedLenderAddress,
        owner.address,
        100,
        nextPoolID
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
  });

  it("BorrowAllowed should fail for when oracle gets weird", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    const dai = exactlyEnv.getUnderlying("DAI");

    const amountDAI = parseUnits("100");
    await dai.approve(fixedLenderDAI.address, amountDAI);
    await fixedLenderDAI.depositToMaturityPool(amountDAI, nextPoolID);

    await auditor.enterMarkets([fixedLenderDAI.address], nextPoolID);

    await exactlyEnv.oracle.setPrice("DAI", 0);
    await expect(
      auditor.borrowAllowed(
        fixedLenderDAI.address,
        owner.address,
        100,
        nextPoolID
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.PRICE_ERROR));
  });

  it("RedeemAllowed should fail for an unlisted market", async () => {
    await expect(
      auditor.redeemAllowed(
        exactlyEnv.notAnFixedLenderAddress,
        owner.address,
        100,
        nextPoolID
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
  });

  it("RepayAllowed should fail for an unlisted market", async () => {
    await expect(
      auditor.repayAllowed(exactlyEnv.notAnFixedLenderAddress, owner.address)
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
  });

  it("SeizeAllowed should fail for an unlisted market", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    await expect(
      auditor.seizeAllowed(
        exactlyEnv.notAnFixedLenderAddress,
        fixedLenderDAI.address,
        owner.address,
        user.address
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
  });

  it("SeizeAllowed should fail when liquidator is borrower", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    await expect(
      auditor.seizeAllowed(
        fixedLenderDAI.address,
        fixedLenderDAI.address,
        owner.address,
        owner.address
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.LIQUIDATOR_NOT_BORROWER));
  });

  it("LiquidateAllowed should fail for unlisted markets", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    await expect(
      auditor.liquidateAllowed(
        exactlyEnv.notAnFixedLenderAddress,
        fixedLenderDAI.address,
        owner.address,
        user.address,
        100,
        nextPoolID
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
    await expect(
      auditor.liquidateAllowed(
        fixedLenderDAI.address,
        exactlyEnv.notAnFixedLenderAddress,
        owner.address,
        user.address,
        100,
        nextPoolID
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
    await expect(
      auditor.liquidateAllowed(
        fixedLenderDAI.address,
        fixedLenderDAI.address,
        owner.address,
        user.address,
        100,
        nextPoolID
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.UNSUFFICIENT_SHORTFALL)); // Any failure except MARKET_NOT_LISTED
  });

  it("PauseBorrow should fail for an unlisted market", async () => {
    await expect(
      auditor.pauseBorrow(exactlyEnv.notAnFixedLenderAddress, true)
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
  });

  it("PauseBorrow should emit event", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    await expect(auditor.pauseBorrow(fixedLenderDAI.address, true)).to.emit(
      auditor,
      "ActionPaused"
    );
  });

  it("PauseBorrow should block borrowing on a listed market", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    const dai = exactlyEnv.getUnderlying("DAI");
    await auditor.pauseBorrow(fixedLenderDAI.address, true);
    // we supply Dai to the protocol
    const amountDAI = parseUnits("100");
    await dai.approve(fixedLenderDAI.address, amountDAI);
    await fixedLenderDAI.depositToMaturityPool(amountDAI, nextPoolID);

    // we make it count as collateral (DAI)
    await auditor.enterMarkets([fixedLenderDAI.address], nextPoolID);
    await expect(
      // user borrows half of it's collateral
      fixedLenderDAI.borrow(amountDAI.div(2), nextPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.BORROW_PAUSED));
  });

  it("Autoadding a market should only be allowed from a fixedLender", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    const dai = exactlyEnv.getUnderlying("DAI");

    // we supply Dai to the protocol
    const amountDAI = parseUnits("100");
    await dai.approve(fixedLenderDAI.address, amountDAI);
    await fixedLenderDAI.depositToMaturityPool(amountDAI, nextPoolID);

    // we make it count as collateral (DAI)
    await expect(
      auditor.borrowAllowed(
        fixedLenderDAI.address,
        owner.address,
        100,
        nextPoolID
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.NOT_A_FIXED_LENDER_SENDER));
  });

  it("SetBorrowCap should emit event", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    await expect(
      auditor.setMarketBorrowCaps([fixedLenderDAI.address], [10])
    ).to.emit(auditor, "NewBorrowCap");
  });

  it("SetBorrowCap should block borrowing more than the cap on a listed market", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    const dai = exactlyEnv.getUnderlying("DAI");
    await auditor.setMarketBorrowCaps([fixedLenderDAI.address], [10]);
    // we supply Dai to the protocol
    const amountDAI = parseUnits("100");
    await dai.approve(fixedLenderDAI.address, amountDAI);
    await fixedLenderDAI.depositToMaturityPool(amountDAI, nextPoolID);

    await expect(
      // user tries to borrow more than the cap
      fixedLenderDAI.borrow(20, nextPoolID)
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_BORROW_CAP_REACHED));
  });

  it("LiquidateCalculateSeizeAmount should fail when oracle is acting weird", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    await exactlyEnv.setOracleMockPrice("DAI", "0");
    await expect(
      auditor.liquidateCalculateSeizeAmount(
        fixedLenderDAI.address,
        fixedLenderDAI.address,
        100
      )
    ).to.be.revertedWith(errorGeneric(ProtocolError.PRICE_ERROR));
  });

  it("Future pools should match JS generated ones", async () => {
    let exaTime = new ExaTime();
    let poolsInContract = await auditor.callStatic.getFuturePools();
    let poolsInJS = exaTime.futurePools(12).map((item) => BigNumber.from(item));
    for (let i = 0; i < 12; i++) {
      expect(poolsInContract[i]).to.be.equal(poolsInJS[i]);
    }
  });

  it("we deposit dai & eth to the protocol and we use them both for collateral to take a loan", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    const dai = exactlyEnv.getUnderlying("DAI");

    // we supply Dai to the protocol
    const amountDAI = parseUnits("100");
    await dai.approve(fixedLenderDAI.address, amountDAI);
    let txDAI = await fixedLenderDAI.depositToMaturityPool(
      amountDAI,
      nextPoolID
    );
    let borrowDAIEvent = await parseDepositToMaturityPoolEvent(txDAI);

    expect(await dai.balanceOf(fixedLenderDAI.address)).to.equal(amountDAI);

    // we make it count as collateral (DAI)
    await auditor.enterMarkets([fixedLenderDAI.address], nextPoolID);

    const fixedLenderETH = exactlyEnv.getFixedLender("ETH");
    const eth = exactlyEnv.getUnderlying("ETH");

    // we supply Eth to the protocol
    const amountETH = parseUnits("1");
    await eth.approve(fixedLenderETH.address, amountETH);
    let txETH = await fixedLenderETH.depositToMaturityPool(
      amountETH,
      nextPoolID
    );
    let borrowETHEvent = await parseDepositToMaturityPoolEvent(txETH);

    expect(await eth.balanceOf(fixedLenderETH.address)).to.equal(amountETH);

    // we make it count as collateral (ETH)
    await auditor.enterMarkets([fixedLenderETH.address], nextPoolID);

    let liquidity = (
      await auditor.getAccountLiquidity(owner.address, nextPoolID)
    )[0];

    let collaterDAI = amountDAI
      .add(borrowDAIEvent.commission)
      .mul(mockedTokens.get("DAI")!.collateralRate)
      .div(parseUnits("1"))
      .mul(mockedTokens.get("DAI")!.usdPrice)
      .div(parseUnits("1"));

    let collaterETH = amountETH
      .add(borrowETHEvent.commission)
      .mul(mockedTokens.get("ETH")!.collateralRate)
      .div(parseUnits("1"))
      .mul(mockedTokens.get("ETH")!.usdPrice)
      .div(parseUnits("1"));

    expect(parseFloat(await formatUnits(liquidity))).to.be.equal(
      parseFloat(formatUnits(collaterDAI.add(collaterETH)))
    );
  });

  it("Auditor reverts if Oracle acts weird", async () => {
    const fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    const dai = exactlyEnv.getUnderlying("DAI");

    // we supply Dai to the protocol
    const amountDAI = parseUnits("100");
    await dai.approve(fixedLenderDAI.address, amountDAI);
    await fixedLenderDAI.depositToMaturityPool(amountDAI, nextPoolID);

    // we make it count as collateral (DAI)
    await auditor.enterMarkets([fixedLenderDAI.address], nextPoolID);

    await exactlyEnv.oracle.setPrice("DAI", 0);
    await expect(
      auditor.getAccountLiquidity(owner.address, nextPoolID)
    ).to.revertedWith(errorGeneric(ProtocolError.PRICE_ERROR));
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
