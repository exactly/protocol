import { ethers } from "hardhat";
import { Contract } from "ethers";

export class RewardsLibEnv {
  auditorHarness: Contract;
  exaLib: Contract;
  exaToken: Contract;
  fixedLenderHarness: Contract;
  eToken: Contract;
  notAnFixedLenderAddress = "0x6D88564b707518209a4Bea1a57dDcC23b59036a8";

  constructor(
    _auditorHarness: Contract,
    _exaLib: Contract,
    _exaToken: Contract,
    _fixedLenderHarness: Contract,
    _eToken: Contract
  ) {
    this.auditorHarness = _auditorHarness;
    this.exaLib = _exaLib;
    this.exaToken = _exaToken;
    this.fixedLenderHarness = _fixedLenderHarness;
    this.eToken = _eToken;
  }

  static async create(): Promise<RewardsLibEnv> {
    const TSUtilsLib = await ethers.getContractFactory("TSUtils");
    let tsUtils = await TSUtilsLib.deploy();
    await tsUtils.deployed();

    const ExaLib = await ethers.getContractFactory("ExaLib");
    let exaLib = await ExaLib.deploy();
    await exaLib.deployed();

    const ExaToken = await ethers.getContractFactory("ExaToken");
    let exaToken = await ExaToken.deploy();
    await exaToken.deployed();

    const EToken = await ethers.getContractFactory("EToken", {});
    let eToken = await EToken.deploy("eDAI", "eDAI", 18);
    await eToken.deployed();

    const FixedLenderHarness = await ethers.getContractFactory(
      "FixedLenderHarness"
    );
    let fixedLenderHarness = await FixedLenderHarness.deploy();
    await fixedLenderHarness.deployed();
    await fixedLenderHarness.setEToken(eToken.address);

    const AuditorHarness = await ethers.getContractFactory("AuditorHarness", {
      libraries: {
        ExaLib: exaLib.address,
      },
    });
    let auditorHarness = await AuditorHarness.deploy(exaToken.address);
    await auditorHarness.deployed();
    await auditorHarness.enableMarket(fixedLenderHarness.address);
    eToken.initialize(fixedLenderHarness.address, auditorHarness.address);

    return new Promise<RewardsLibEnv>((resolve) => {
      resolve(
        new RewardsLibEnv(
          auditorHarness,
          exaLib,
          exaToken,
          fixedLenderHarness,
          eToken
        )
      );
    });
  }
}
