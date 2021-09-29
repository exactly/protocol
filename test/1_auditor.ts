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
    ["ETH", parseUnits("3100", 6)],
  ]);

  beforeEach(async () => {
    [owner, user] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(tokensUSDPrice, tokensCollateralRate);
    auditor = exactlyEnv.auditor;
  });

  it("we deposit dai & eth to the protocol and we use them both for collateral to take a loan", async () => {
    const exafinDai = exactlyEnv.getExafin("DAI");
    const dai = exactlyEnv.getUnderlying("DAI");
    const nextPoolID = (new ExaTime()).nextPoolID();

    // we supply Dai to the protocol
    const amountDAI = parseUnits("100", 18);
    await dai.approve(exafinDai.address, amountDAI);
    let txDAI = await exafinDai.supply(owner.address, amountDAI, nextPoolID);
    let borrowDAIEvent = await parseSupplyEvent(txDAI);

    expect(await dai.balanceOf(exafinDai.address)).to.equal(amountDAI);

    // we make it count as collateral (DAI)
    await auditor.enterMarkets([exafinDai.address]);

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

    // we supply Eth to the protocol
    const amountETH = parseUnits("1", 18);
    await eth.approve(exafinETH.address, amountETH);
    
    expect(await eth.balanceOf(exafinETH.address)).to.equal(amountETH);

    // we make it count as collateral (ETH)
    await auditor.enterMarkets([exafinETH.address]);
    let liquidity = (await auditor.getAccountLiquidity(owner.address, nextPoolID))[0];

    // user borrows all liquidity
    let exafinDAI = exactlyEnv.getExafin("DAI");
    await exafinDAI.borrow(owner.address, liquidity, nextPoolID);


  });
});
