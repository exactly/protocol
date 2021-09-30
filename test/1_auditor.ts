import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { ExactlyEnv, ExaTime, parseSupplyEvent } from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Auditor", function () {
  let auditor: Contract;
  let exactlyEnv: ExactlyEnv;

  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  let tokensCollateralRate = new Map([
    ["DAI", parseUnits("0.8", 18)],
    ["ETH", parseUnits("0.7", 18)],
  ]);

  // Oracle price is in 10**6
  let tokensUSDPrice = new Map([
    ["DAI", parseUnits("1", 6)],
    ["ETH", parseUnits("3000", 6)],
  ]);

  let closeFactor = parseUnits("0.4");

  beforeEach(async () => {
    [owner, user] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(tokensUSDPrice, tokensCollateralRate);
    auditor = exactlyEnv.auditor;

    // From Owner to User
    await exactlyEnv.getUnderlying("DAI").transfer(user.address, parseUnits("10000"));
  });

  it("we deposit dai & eth to the protocol and we use them both for collateral to take a loan", async () => {
    const exafinDAI = exactlyEnv.getExafin("DAI");
    const dai = exactlyEnv.getUnderlying("DAI");
    const nextPoolID = (new ExaTime()).nextPoolID();

    // we supply Dai to the protocol
    const amountDAI = parseUnits("100", 18);
    await dai.approve(exafinDAI.address, amountDAI);
    let txDAI = await exafinDAI.supply(owner.address, amountDAI, nextPoolID);
    let borrowDAIEvent = await parseSupplyEvent(txDAI);

    expect(await dai.balanceOf(exafinDAI.address)).to.equal(amountDAI);

    // we make it count as collateral (DAI)
    await auditor.enterMarkets([exafinDAI.address]);

    const exafinETH = exactlyEnv.getExafin("ETH");
    const eth = exactlyEnv.getUnderlying("ETH");

    // we supply Eth to the protocol
    const amountETH = parseUnits("1", 18);
    await eth.approve(exafinETH.address, amountETH);
    let txETH = await exafinETH.supply(owner.address, amountETH, nextPoolID);
    let borrowETHEvent = await parseSupplyEvent(txETH);

    expect(await eth.balanceOf(exafinETH.address)).to.equal(amountETH);

    // we make it count as collateral (ETH)
    await auditor.enterMarkets([exafinETH.address]);

    let liquidity = (await auditor.getAccountLiquidity(owner.address, nextPoolID))[0];
    let collaterDAI = amountDAI
      .add(borrowDAIEvent.commission)
      .mul(tokensCollateralRate.get("DAI")!)
      .div(parseUnits("1", 18))
      .mul(tokensUSDPrice.get("DAI")!)
      .div(parseUnits("1", 6));

    let collaterETH = amountETH
      .add(borrowETHEvent.commission)
      .mul(tokensCollateralRate.get("ETH")!)
      .div(parseUnits("1", 18))
      .mul(tokensUSDPrice.get("ETH")!)
      .div(parseUnits("1", 6));

    expect(liquidity).to.be.equal(collaterDAI.add(collaterETH));
  });

  it("Uncollaterized position can be liquidated", async () => {
    const nextPoolID = (new ExaTime()).nextPoolID();
    const exafinETH = exactlyEnv.getExafin("ETH");
    const eth = exactlyEnv.getUnderlying("ETH");
    const exafinDAI = exactlyEnv.getExafin("DAI");
    const dai = exactlyEnv.getUnderlying("DAI");

    // we supply Eth to the protocol
    const amountETH = parseUnits("1", 18);
    await eth.approve(exafinETH.address, amountETH);
    await exafinETH.supply(owner.address, amountETH, nextPoolID);
    
    expect(await eth.balanceOf(exafinETH.address)).to.equal(amountETH);

    // we supply DAI to the protocol
    const amountDAI = parseUnits("5000", 18);
    await dai.connect(user).approve(exafinDAI.address, amountDAI);
    await exafinDAI.connect(user).supply(user.address, amountDAI, nextPoolID);

    expect(await dai.connect(user).balanceOf(exafinDAI.address)).to.equal(amountDAI);

    // we make it count as collateral (ETH)
    await auditor.enterMarkets([exafinETH.address]);
    let liquidity = (await auditor.getAccountLiquidity(owner.address, nextPoolID))[0];

    // user borrows all liquidity
    await exafinDAI.borrow(liquidity, nextPoolID);

    // ETH price goes to 1/2 of its original value
    await exactlyEnv.setOraclePrice("ETH", "1500");

    // We expect liquidity to be equal to zero
    let liquidityAfter = (await auditor.getAccountLiquidity(owner.address, nextPoolID));
    expect(liquidityAfter[0]).to.be.equal(0);

    // We try to get all the ETH we can
    // We expect trying to repay zero to fail
    await expect(
      exafinDAI.liquidate(owner.address, 0, exafinETH.address, nextPoolID)
    ).to.be.revertedWith("Repay amount shouldn't be zero");

    // We expect self liquidation to fail
    await expect(
      exafinDAI.liquidate(owner.address, liquidityAfter[1], exafinETH.address, nextPoolID)
    ).to.be.revertedWith("Liquidator shouldn't be borrower");

    // We expect liquidation to fail because trying to liquidate too much
    await expect(
      exafinDAI.connect(user).liquidate(owner.address, liquidityAfter[1], exafinETH.address, nextPoolID)
    ).to.be.revertedWith("Too Much Repay");

    let closeToMaxRepay = liquidityAfter[1]
        .mul(closeFactor)
        .div(parseUnits("1"));

    await dai.connect(user).approve(exafinDAI.address, closeToMaxRepay);
    await exafinDAI.connect(user).liquidate(
      owner.address,
      closeToMaxRepay,
      exafinETH.address,
      nextPoolID);
  });
});
