import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv, ExactlyEnv } from "./exactlyUtils";

describe("Smart Pool", function () {
  let exactlyEnv: DefaultEnv;

  let underlyingToken: Contract;
  let exafin: Contract;
  let bob: SignerWithAddress;
  let laura: SignerWithAddress;

  const mockedTokens = new Map([
    [
      "DAI",
      {
        decimals: 18,
        collateralRate: parseUnits("0.8"),
        usdPrice: parseUnits("1"),
      },
    ],
  ]);

  beforeEach(async () => {
    [bob, laura] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(mockedTokens);

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    exafin = exactlyEnv.getExafin("DAI");

    // From Owner to User
    await underlyingToken.transfer(bob.address, parseUnits("1000"));
  });

  it("DepositToSmartPool should transfer underlying asset amount to contract", async () => {
    let amountToDeposit = parseUnits("100");
    await underlyingToken.approve(exafin.address, amountToDeposit);
    await exafin.depositToSmartPool(amountToDeposit);

    let balanceOfAssetInContract = await underlyingToken.balanceOf(
      exafin.address
    );

    expect(balanceOfAssetInContract).to.equal(amountToDeposit);
  });

  it("WithdrawFromSmartPool should transfer underlying asset amount from contract", async () => {
    let amountToWithdraw = parseUnits("100");
    await underlyingToken.transfer(laura.address, amountToWithdraw);

    await underlyingToken
      .connect(laura)
      .approve(exafin.address, amountToWithdraw);
    await exafin.connect(laura).depositToSmartPool(amountToWithdraw);

    await exafin.connect(laura).withdrawFromSmartPool(amountToWithdraw);
    let balanceOfAssetInUserAddress = await underlyingToken.balanceOf(
      laura.address
    );

    expect(balanceOfAssetInUserAddress).to.equal(amountToWithdraw);
  });

  it.only("WithdrawFromSmartPool should fail when eToken balance is lower than withdraw amount", async () => {
    let amountToDeposit = parseUnits("100");
    let amountToWithdraw = parseUnits("200");
    await underlyingToken.approve(exafin.address, amountToDeposit);
    await exafin.depositToSmartPool(amountToDeposit);

    await expect(exafin.withdrawFromSmartPool(amountToWithdraw)).to.be.reverted;
  });
});
