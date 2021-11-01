import { ethers } from "hardhat";
import { expect } from "chai";
import { Contract } from "ethers";
import {
  DefaultEnv,
  errorGeneric,
  ExactlyEnv,
  ExaTime,
  parseBorrowEvent,
  ProtocolError,
  RewardsLibEnv,
} from "./exactlyUtils";
import { parseUnits, formatUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("ExaToken", function() {
  let exactlyEnv: DefaultEnv;
  let rewardsLibEnv: RewardsLibEnv;

  let dai: Contract;
  let exafinDAI: Contract;
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

    rewardsLibEnv = await ExactlyEnv.createRewardsEnv();

    dai = exactlyEnv.getUnderlying("DAI");
    exafinDAI = exactlyEnv.getExafin("DAI");
    auditor = exactlyEnv.auditor;

    // From Owner to User
    await dai.transfer(mariaUser.address, parseUnits("1000"));
  });

  describe("setExaSpeed Integrated", function() {

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

    it("should update rewards in the supply market", async () => {
      let someAuditor = rewardsLibEnv.someAuditor;
      // 1 EXA per block as rewards
      await someAuditor.setBlockNumber(0);
      await someAuditor.setExaSpeed(exafinDAI.address, parseUnits("1"));
      // 2 EXA per block as rewards
      await someAuditor.setBlockNumber(1);
      await someAuditor.setExaSpeed(exafinDAI.address, parseUnits("2"));

      // ... but updated on the initial speed
      const [index, block] = await someAuditor.getSupplyState(exafinDAI.address);
      expect(index).to.equal(parseUnits("1", 36));
      expect(block).to.equal(1);
    });

    it("should NOT update rewards in the supply market after being set to 0", async () => {
      let someAuditor = rewardsLibEnv.someAuditor;
      // 1 EXA per block as rewards
      await someAuditor.setBlockNumber(0);
      await someAuditor.setExaSpeed(exafinDAI.address, parseUnits("1"));

      // 0 EXA per block as rewards
      await someAuditor.setBlockNumber(1);
      await someAuditor.setExaSpeed(exafinDAI.address, parseUnits("0"));
      // 2 EXA per block as rewards but no effect
      await someAuditor.setBlockNumber(2);
      await someAuditor.setExaSpeed(exafinDAI.address, parseUnits("2"));

      // ... but updated on the initial speed
      const [index, block] = await someAuditor.getSupplyState(exafinDAI.address);
      expect(index).to.equal(parseUnits("1", 36));
      expect(block).to.equal(1);
    });

  })

  describe('updateExaBorrowIndex', () => {

    it('should calculate EXA borrower state index correctly', async () => {
      let amountBorrowWithCommission = parseUnits("55");
      let exafin = rewardsLibEnv.exafin;
      let someAuditor = rewardsLibEnv.someAuditor;
      let blocksDelta = 2;

      await exafin.setTotalBorrows(amountBorrowWithCommission);

      // Call exaSpeed and jump blocksDelta
      await someAuditor.setBlockNumber(0);
      await someAuditor.setExaSpeed(exafin.address, parseUnits("0.5"));
      await someAuditor.setBlockNumber(blocksDelta);
      await someAuditor.updateExaBorrowIndex(exafin.address);
      const [newIndex,] = await someAuditor.getBorrowState(exafin.address);
      /*
        exaAccrued = deltaBlocks * borrowSpeed
                    = 2 * 0.5e18 = 1e18
        newIndex   += 1e36 + (exaAccrued * 1e36 / borrowAmt(w commission))
                    = 1e36 + (5e18 * 1e36 / 0.5e18) = ~1.019e36
      */
      let exaAccruedDelta = parseUnits("0.5").mul(blocksDelta);
      let ratioDelta = exaAccruedDelta
        .mul(parseUnits("1", 36))
        .div(amountBorrowWithCommission)

      let newIndexCalculated = parseUnits("1", 36).add(ratioDelta);
      expect(newIndex).to.be.equal(newIndexCalculated);
    });

    it('should not update index if no blocks passed since last accrual', async () => {
      let someAuditor = rewardsLibEnv.someAuditor;
      let exafin = rewardsLibEnv.exafin;
      await someAuditor.setBlockNumber(0);
      await someAuditor.setExaSpeed(exafin.address, parseUnits("0.5"));
      await exafin.setTotalBorrows(parseUnits("10000"));
      await someAuditor.updateExaBorrowIndex(exafin.address);

      const [newIndex,block] = await someAuditor.getBorrowState(exafin.address);
      expect(newIndex).to.equal(parseUnits("1", 36));
      expect(block).to.equal(0);
    });

    it('should not update index if EXA speed is 0', async () => {
      let someAuditor = rewardsLibEnv.someAuditor;
      let exafin = rewardsLibEnv.exafin;
      // Update borrows
      await someAuditor.setBlockNumber(0);
      await someAuditor.setExaSpeed(exafin.address, parseUnits("0.5"));
      await someAuditor.setBlockNumber(100);
      await someAuditor.setExaSpeed(exafin.address, 0);
      await exafin.setTotalBorrows(parseUnits("10000"));
      await someAuditor.updateExaBorrowIndex(exafin.address);

      const [newIndex,block] = await someAuditor.getBorrowState(exafin.address);
      expect(newIndex).to.equal(parseUnits("1", 36));
      expect(block).to.equal(100);

    });
  });

  describe('updateExaSupplyIndex', () => {
    it('should calculate EXA supplier index correctly', async () => {

      let amountSupplyWithCommission = parseUnits("10");
      let exafin = rewardsLibEnv.exafin;
      let someAuditor = rewardsLibEnv.someAuditor;
      let blocksDelta = 100;

      // Call exaSpeed and jump blocksDelta
      await someAuditor.setBlockNumber(0);
      await someAuditor.setExaSpeed(exafin.address, parseUnits("0.5"));
      await someAuditor.setBlockNumber(blocksDelta);
      await exafin.setTotalDeposits(amountSupplyWithCommission);
      await someAuditor.updateExaSupplyIndex(exafin.address);
      const [newIndex,] = await someAuditor.getSupplyState(exafin.address);
      /*
        exaAccrued = deltaBlocks * borrowSpeed
                    = 100 * 0.5e18 = 50e18
        newIndex   += 1e36 + (exaAccrued * 1e36 / supplyWithCommission)
                    = 1e36 + (50-8 * 1e36 / 0.5e18) = ~1.019e36
      */
      let exaAccruedDelta = parseUnits("0.5").mul(blocksDelta);
      let ratioDelta = exaAccruedDelta
        .mul(parseUnits("1", 36))
        .div(amountSupplyWithCommission)

      let newIndexCalculated = parseUnits("1", 36).add(ratioDelta);
      expect(newIndex).to.be.equal(newIndexCalculated);

    });

    it('should not update index if no blocks passed since last accrual', async () => {
      let someAuditor = rewardsLibEnv.someAuditor;
      let exafin = rewardsLibEnv.exafin;
      await someAuditor.setBlockNumber(0);
      await someAuditor.setExaSpeed(exafin.address, parseUnits("0.5"));
      await exafin.setTotalDeposits(parseUnits("10000"));
      await someAuditor.updateExaSupplyIndex(exafin.address);

      const [newIndex,block] = await someAuditor.getSupplyState(exafin.address);
      expect(newIndex).to.equal(parseUnits("1", 36));
      expect(block).to.equal(0);
    });

    it('should not update index if EXA speed is 0', async () => {
      let someAuditor = rewardsLibEnv.someAuditor;
      let exafin = rewardsLibEnv.exafin;
      // Update borrows
      await someAuditor.setBlockNumber(0);
      await someAuditor.setExaSpeed(exafin.address, parseUnits("0.5"));
      await someAuditor.setBlockNumber(100);
      await someAuditor.setExaSpeed(exafin.address, 0);
      await exafin.setTotalDeposits(parseUnits("10000"));
      await someAuditor.updateExaSupplyIndex(exafin.address);

      const [newIndex,block] = await someAuditor.getSupplyState(exafin.address);
      expect(newIndex).to.equal(parseUnits("1", 36));
      expect(block).to.equal(100);

    });

  });
});
