import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { ProtocolError, ExactlyEnv, ExaTime, errorGeneric, DefaultEnv } from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Auditor Admin", function () {
  let auditor: Contract;
  let exactlyEnv: DefaultEnv;
  let nextPoolID: number;

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
    nextPoolID = (new ExaTime()).nextPoolID();

    // From Owner to User
    await exactlyEnv.getUnderlying("DAI").transfer(user.address, parseUnits("10000"));
  });

  it("EnableMarket should fail from third parties", async () => {
    await expect(
      auditor.connect(user).enableMarket(exactlyEnv.getExafin("DAI").address, 0, "DAI", "DAI")
    ).to.be.revertedWith("AccessControl");
  });

  it("It reverts when trying to list a market twice", async () => {
    await expect(
      auditor.enableMarket(exactlyEnv.getExafin("DAI").address, 0, "DAI", "DAI")
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_ALREADY_LISTED));
  });

  it("It reverts when trying to set an exafin with different auditor", async () => {

    const Auditor = await ethers.getContractFactory("Auditor", {
      libraries: {
        TSUtils: exactlyEnv.tsUtils.address,
        ExaLib: exactlyEnv.exaLib.address
      }
    });
    let newAuditor = await Auditor.deploy(
      exactlyEnv.oracle.address,
      exactlyEnv.exaToken.address
    );
    await newAuditor.deployed();

    const Exafin = await ethers.getContractFactory("Exafin", {
      libraries: {
        TSUtils: exactlyEnv.tsUtils.address
      }
    });
    const exafin = await Exafin.deploy(
      exactlyEnv.getUnderlying("DAI").address,
      "DAI",
      newAuditor.address,
      exactlyEnv.interestRateModel.address
    );
    await exafin.deployed();

    await expect(
      auditor.enableMarket(exafin.address, 0, "DAI", "DAI")
    ).to.be.revertedWith(errorGeneric(ProtocolError.AUDITOR_MISMATCH));
  });


  it("It should emit an event when listing a new market", async () => {
    const TSUtilsLib = await ethers.getContractFactory("TSUtils");
    let tsUtils = await TSUtilsLib.deploy();
    await tsUtils.deployed();

    const Exafin = await ethers.getContractFactory("Exafin", {
      libraries: {
        TSUtils: tsUtils.address
      }
    });
    const exafin = await Exafin.deploy(
      exactlyEnv.getUnderlying("DAI").address,
      "DAI2",
      auditor.address,
      exactlyEnv.interestRateModel.address
    );
    await exafin.deployed();

    await expect(
      auditor.enableMarket(exafin.address, parseUnits("0.5"), "DAI2", "DAI2")
    ).to.emit(auditor, "MarketListed").withArgs(exafin.address);
  });

  it("SetOracle should fail from third parties", async () => {
    await expect(
      auditor.connect(user).setOracle(exactlyEnv.oracle.address)
    ).to.be.revertedWith("AccessControl");
  });

  it("SetOracle should emit event", async () => {
    await expect(
      auditor.setOracle(exactlyEnv.oracle.address)
    ).to.emit(auditor, "OracleChanged");
  });

  it("GetMarketAddresses should return all markets", async () => {
    let addresses = await auditor.getMarketAddresses()

    expect(addresses[0]).to.equal(exactlyEnv.getExafin("DAI").address);
    expect(addresses[1]).to.equal(exactlyEnv.getExafin("ETH").address);
  });

  it("SetMarketBorrowCaps should fail from third parties", async () => {
    let exafinDAI = exactlyEnv.getExafin("DAI");
    await expect(
      auditor.connect(user).setMarketBorrowCaps([exafinDAI.address], [0])
    ).to.be.revertedWith("AccessControl");
  });

  it("SetMarketBorrowCaps should fail when wrong arguments", async () => {
    let exafinDAI = exactlyEnv.getExafin("DAI");
    await expect(
      auditor.setMarketBorrowCaps([exafinDAI.address], [])
    ).to.be.revertedWith(errorGeneric(ProtocolError.INVALID_SET_BORROW_CAP));
  });

  it("SetMarketBorrowCaps should fail when wrong market", async () => {
    await expect(
      auditor.setMarketBorrowCaps([exactlyEnv.notAnExafinAddress], [parseUnits("1000")])
    ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
  });

  it("SetMarketBorrowCaps should emit events", async () => {
    let exafinDAI = exactlyEnv.getExafin("DAI");
    await expect(
      auditor.setMarketBorrowCaps([exafinDAI.address], [parseUnits("1000")])
    ).to.emit(auditor, "NewBorrowCap");
  });

  it("SetExaSpeed should emit events", async () => {
    let exafinDAI = exactlyEnv.getExafin("DAI");
    await expect(
      auditor.setExaSpeed(exafinDAI.address, parseUnits("3000"))
    ).to.emit(auditor, "ExaSpeedUpdated");
  });

});
