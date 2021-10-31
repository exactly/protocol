import { ethers } from "hardhat";
import { expect } from "chai";
import { Contract } from "ethers";
import {
  errorGeneric,
  ExactlyEnv,
  ExaTime,
  ProtocolError,
} from "./exactlyUtils";
import { parseUnits, formatUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

Error.stackTraceLimit = Infinity;

describe("ExaToken", function() {
  let exactlyEnv: ExactlyEnv;

  let underlyingToken: Contract;
  let exafin: Contract;
  let auditor: Contract;

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
  let exaTime: ExaTime = new ExaTime();

  let snapshot: any;

  beforeEach(async () => {
    [owner, mariaUser, johnUser] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(tokensUSDPrice, tokensCollateralRate);

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    exafin = exactlyEnv.getExafin("DAI");
    auditor = exactlyEnv.auditor;

    // From Owner to User
    await underlyingToken.transfer(mariaUser.address, parseUnits("10"));
  });

  describe("setExaSpeed", function() {
    it("should update rewards in the supply market", async () => {
      // 1 EXA per block as rewards
      await auditor.setExaSpeed(exactlyEnv.getExafin("DAI").address, parseUnits("1"));
      const [, initialBlock] = await auditor.getSupplyState(exactlyEnv.getExafin("DAI").address);

      // 2 EXA per block as rewards
      await auditor.setExaSpeed(exactlyEnv.getExafin("DAI").address, parseUnits("2"));

      // ... but updated on the initial speed
      const [index, block] = await auditor.getSupplyState(exactlyEnv.getExafin("DAI").address);
      expect(index).to.equal(parseUnits("1", 36));
      expect(block - initialBlock).to.equal(1);
    });

    it("should NOT update rewards in the supply market after being set to 0", async () => {
      // 1 EXA per block as rewards
      await auditor.setExaSpeed(exactlyEnv.getExafin("DAI").address, parseUnits("1"));
      const [, initialBlock] = await auditor.getSupplyState(exactlyEnv.getExafin("DAI").address);

      // 0 EXA per block as rewards
      await auditor.setExaSpeed(exactlyEnv.getExafin("DAI").address, parseUnits("0"));
      // 2 EXA per block as rewards but no effect
      await auditor.setExaSpeed(exactlyEnv.getExafin("DAI").address, parseUnits("2"));

      // ... but updated on the initial speed
      const [index, block] = await auditor.getSupplyState(exactlyEnv.getExafin("DAI").address);
      expect(index).to.equal(parseUnits("1", 36));
      expect(block - initialBlock).to.equal(1);
    });

    it("should revert if non admin access", async () => {
      await expect(
        auditor.connect(mariaUser).setExaSpeed(exactlyEnv.getExafin("DAI").address, parseUnits("1"))
      ).to.be.revertedWith("AccessControl");
    });

    it("should revert if an invalid exafin address", async () => {
      await expect(
        auditor.setExaSpeed(exactlyEnv.notAnExafinAddress, parseUnits("1"))
      ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
    });

  })
});
