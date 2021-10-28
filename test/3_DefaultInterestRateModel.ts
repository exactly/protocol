import { expect } from "chai";
import { ethers } from "hardhat";
import { formatUnits, parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { ProtocolError, ExactlyEnv, ExaTime, parseSupplyEvent, errorGeneric } from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { parseEther } from "ethers/lib/utils";

describe("DefaultInterestRateModel", () => {
  let exactlyEnv: ExactlyEnv;

  let underlyingToken: Contract;
  let eth: Contract;
  let exafin: Contract;
  let exafin2: Contract;
  let auditor: Contract;
  let interestRateModel: Contract;

  let tokensCollateralRate = new Map([
    ["DAI", parseUnits("0.8", 18)],
    ["ETH", parseUnits("0.7", 18)],
  ]);

  // Oracle price is in 10**6
  let tokensUSDPrice = new Map([
    ["DAI", parseUnits("1", 6)],
    ["ETH", parseUnits("3100", 6)],
  ]);

  let mariaUser: SignerWithAddress;
  let johnUser: SignerWithAddress;
  let owner: SignerWithAddress;
  let exaTime: ExaTime;

  let snapshot: any;

  beforeEach(async () => {
    [owner, mariaUser, johnUser] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(tokensUSDPrice, tokensCollateralRate);

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    eth = exactlyEnv.getUnderlying("ETH");

    exafin = exactlyEnv.getExafin("DAI");
    exafin2 = exactlyEnv.getExafin("ETH");
    auditor = exactlyEnv.auditor;
    interestRateModel = exactlyEnv.interestRateModel;
    // From Owner to User
    underlyingToken.transfer(mariaUser.address, parseUnits("1000000"));
    eth.transfer(mariaUser.address, parseEther("100"));
    exaTime = new ExaTime();

    // This can be optimized (so we only do it once per file, not per test)
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  it("Supply 1, borrow 2, borrow 2", async () => {
    const pool = {
      borrowed: 4,
      supplied: 4,
      debt: 3,
      available: 0,
    };

    const smartPool = {
      borrowed: 3,
      supplied: 100000,
    };

    console.log(
      formatUnits(await interestRateModel.getRateToBorrow(1, exaTime.futurePools(6)[1], pool, smartPool, true))
    );
  });

  it("Borrow 10000, supply 10000", async () => {
    const pool = {
      borrowed: 10000,
      supplied: 10000,
      debt: 0,
      available: 0,
    };

    const smartPool = {
      borrowed: 10000,
      supplied: 110000,
    };

    console.log(formatUnits(await interestRateModel.getRateToBorrow(1, exaTime.nextPoolID(), pool, smartPool, true)));
  });

  // it("Third", async () => {
  //   let exafinMaria = exafin.connect(mariaUser);
  //   let exafin2Maria = exafin2.connect(mariaUser);
  //   let auditorUser = auditor.connect(mariaUser);
  //   let underlyingTokenUser = underlyingToken.connect(mariaUser);
  //   let ethUser = eth.connect(mariaUser);

  //   const approvedAmount = parseUnits("1000000");
  //   const supplyAmount = parseUnits("10000");
  //   const borrowAmount = parseUnits("10000");

  //   await underlyingTokenUser.approve(exafin.address, approvedAmount);
  //   await ethUser.approve(exafin2.address, parseEther("10"));

  //   await exafin2Maria.supply(mariaUser.address, parseEther("10"), exaTime.nextPoolID());

  //   await exafinMaria.smartPoolSupply(mariaUser.address, parseUnits("100000"));
  //   await auditorUser.enterMarkets([exafin.address, exafin2.address]);

  //   await expect(auditor.borrowAllowed(exafin.address, mariaUser.address, borrowAmount, exaTime.nextPoolID())).to.not.be
  //     .reverted;

  //   console.log("Vault pre transaccion: ", await formatUnits(await exafin.currentBalance()));

  //   await exafinMaria.borrow(borrowAmount, exaTime.nextPoolID());

  //   console.log("Vault post transaccion: ", await formatUnits(await exafin.currentBalance()));
  //   // await exafinMaria.supply(
  //   //   mariaUser.address,
  //   //   supplyAmount,
  //   //   exaTime.nextPoolID()
  //   // );
  //   console.log("Vault post second transaccion: ", await formatUnits(await exafin.currentBalance()));
  // });

  // it("Fourth", async () => {
  //   let exafinMaria = exafin.connect(mariaUser);
  //   let exafin2Maria = exafin2.connect(mariaUser);
  //   let auditorUser = auditor.connect(mariaUser);
  //   let underlyingTokenUser = underlyingToken.connect(mariaUser);
  //   let ethUser = eth.connect(mariaUser);

  //   const approvedAmount = parseUnits("1000000");
  //   const supplyAmount = parseUnits("10000");
  //   const borrowAmount = parseUnits("10000");

  //   await underlyingTokenUser.approve(exafin.address, approvedAmount);
  //   await ethUser.approve(exafin2.address, parseEther("10"));

  //   await exafin2Maria.supply(mariaUser.address, parseEther("10"), exaTime.nextPoolID());

  //   // await exafinMaria.smartPoolSupply(mariaUser.address, parseUnits("100000"));
  //   await auditorUser.enterMarkets([exafin.address, exafin2.address]);

  //   await expect(auditor.borrowAllowed(exafin.address, mariaUser.address, borrowAmount, exaTime.nextPoolID())).to.not.be
  //     .reverted;

  //   console.log("Vault pre transaccion: ", await formatUnits(await exafin.currentBalance()));

  //   await expect(exafinMaria.borrow(borrowAmount, exaTime.nextPoolID())).to.be.reverted;
  // });
});
