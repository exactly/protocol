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
  let owner: SignerWithAddress;

  beforeEach(async () => {
    exactlyEnv = await ExactlyEnv.create(tokensUSDPrice, tokensCollateralRate);
    rewardsLibEnv = await ExactlyEnv.createRewardsEnv();
  }); 

  describe("setExaSpeed Integrated", function() {
    let dai: Contract;
    let exafinDAI: Contract;
    let auditor: Contract;

    beforeEach(async () => {
      [owner, mariaUser] = await ethers.getSigners();

      dai = exactlyEnv.getUnderlying("DAI");
      exafinDAI = exactlyEnv.getExafin("DAI");
      auditor = exactlyEnv.auditor;

      // From Owner to User
      await dai.transfer(mariaUser.address, parseUnits("1000"));
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

  describe('distributeBorrowerExa', () => {
    let someAuditor: Contract;
    let exafin: Contract;
    let exaToken: Contract;

    beforeEach(async () => {
      someAuditor = rewardsLibEnv.someAuditor;
      exafin = rewardsLibEnv.exafin;
      exaToken = rewardsLibEnv.exaToken;
    });

    it('should update borrow index checkpoint but not exaAccrued for first time user', async () => {
      let borrowIndex = parseUnits("6", 36)
      await someAuditor.setExaBorrowState(exafin.address, borrowIndex, 10);

      await exafin.setTotalBorrows(parseUnits("10000"));
      await exafin.setBorrowsOf(owner.address, parseUnits("100"));

      await someAuditor.distributeBorrowerExa(exafin.address, owner.address);

      expect(await someAuditor.getExaAccrued(owner.address)).to.equal(0);
      const [newIndex,] = await someAuditor.getBorrowState(exafin.address);
      expect(newIndex).to.equal(borrowIndex);
    });

    it('should transfer EXA and update borrow index checkpoint correctly for repeat time user', async () => {
      await exaToken.transfer(someAuditor.address, parseUnits("50"));
      await exafin.setBorrowsOf(mariaUser.address, parseUnits("5"));
      await someAuditor.setExaBorrowState(exafin.address, parseUnits("6", 36), 10);
      await someAuditor.setExaBorrowerIndex(exafin.address, mariaUser.address, parseUnits("1", 36));

      /**
       * this tests that an acct with half the total borrows over that time gets 25e18 EXA
       * borrowerAmount = 5e18
       * deltaIndex     = marketStoredIndex - userStoredIndex
       *                = 6e36 - 1e36 = 5e36
       * borrowerAccrued= borrowerAmount * deltaIndex / 1e36
       *                = 5e18 * 5e36 / 1e36 = 25e18
       */

      let tx = await someAuditor.distributeBorrowerExa(exafin.address, mariaUser.address);
      let accrued = await someAuditor.getExaAccrued(mariaUser.address);

      expect(accrued).to.equal(parseUnits("25"));
      expect(await exaToken.balanceOf(mariaUser.address)).to.equal(0);
      expect(tx).to.emit(someAuditor, "DistributedBorrowerExa").withArgs(
        exafin.address,
        mariaUser.address,
        parseUnits("25"),
        parseUnits("6", 36)
      );
    });

    it('should not transfer EXA automatically', async () => {
      await exaToken.transfer(someAuditor.address, parseUnits("50"));
      await exafin.setBorrowsOf(mariaUser.address, parseUnits("0.5"));
      await someAuditor.setExaBorrowState(exafin.address, parseUnits("1.0019", 36), 10);
      await someAuditor.setExaBorrowerIndex(exafin.address, mariaUser.address, parseUnits("1", 36));
      /*
       * borrowerAmount =  5e17
       * deltaIndex     = marketStoredIndex - userStoredIndex
       *                = 1.0019e36 - 1e36 = 0.0019e36
       * borrowerAccrued= borrowerAmount * deltaIndex / 1e36
       *                = 5e17 * 0.0019e36 / 1e36 = 0.00095e18
      */
      let tx = await someAuditor.distributeBorrowerExa(exafin.address, mariaUser.address);
      let accrued = await someAuditor.getExaAccrued(mariaUser.address);

      expect(accrued).to.equal(parseUnits("0.00095"));
      expect(await exaToken.balanceOf(mariaUser.address)).to.equal(0);
    });

  });

  describe('distributeSupplierExa', () => {
    let someAuditor: Contract;
    let exafin: Contract;
    let exaToken: Contract;

    beforeEach(async () => {
      someAuditor = rewardsLibEnv.someAuditor;
      exafin = rewardsLibEnv.exafin;
      exaToken = rewardsLibEnv.exaToken;
    });

    it('should transfer EXA and update supply index correctly for first time user', async () => {
      await exaToken.transfer(someAuditor.address, parseUnits("50"));
      await exafin.setSuppliesOf(mariaUser.address, parseUnits("5"));
      await someAuditor.setExaSupplyState(exafin.address, parseUnits("6", 36), 10);

      /**
       * 100 delta blocks, 10e18 total supply, 0.5e18 supplySpeed => 6e18 exaSupplyIndex
       * confirming an acct with half the total supply over that time gets 25e18 EXA:
       * supplierAmount  = 5e18
       * deltaIndex      = marketStoredIndex - userStoredIndex
       *                 = 6e36 - 1e36 = 5e36
       * suppliedAccrued+= supplierTokens * deltaIndex / 1e36
       *                 = 5e18 * 5e36 / 1e36 = 25e18
       */
      let tx = await someAuditor.distributeAllSupplierExa(exafin.address, mariaUser.address);
      let accrued = await someAuditor.getExaAccrued(mariaUser.address);
      let balance = await exaToken.balanceOf(mariaUser.address);
      expect(accrued).to.equal(0);
      expect(balance).to.equal(parseUnits("25"));
      expect(tx).to.emit(someAuditor, "DistributedSupplierExa").withArgs(
        exafin.address,
        mariaUser.address,
        parseUnits("25"),
        parseUnits("6", 36)
      )
    });

    it('should update EXA accrued and supply index for repeat user', async () => {
      await exaToken.transfer(someAuditor.address, parseUnits("50"));
      await exafin.setSuppliesOf(mariaUser.address, parseUnits("5"));
      await someAuditor.setExaSupplyState(exafin.address, parseUnits("6", 36), 10);
      await someAuditor.setExaSupplierIndex(exafin.address, mariaUser.address, parseUnits("2", 36));
      /**
       * supplierAmount  = 5e18
       * deltaIndex      = marketStoredIndex - userStoredIndex
       *                 = 6e36 - 2e36 = 4e36
       * suppliedAccrued+= supplierTokens * deltaIndex / 1e36
       *                 = 5e18 * 4e36 / 1e36 = 20e18
      */
      let tx = await someAuditor.distributeAllSupplierExa(exafin.address, mariaUser.address);
      let accrued = await someAuditor.getExaAccrued(mariaUser.address);
      let balance = await exaToken.balanceOf(mariaUser.address);
      expect(accrued).to.equal(0);
      expect(balance).to.equal(parseUnits("20"));
    });

    it('should not transfer EXA automatically', async () => {
      await exaToken.transfer(someAuditor.address, parseUnits("50"));
      await exafin.setSuppliesOf(mariaUser.address, parseUnits("0.5"));
      await someAuditor.setExaSupplyState(exafin.address, parseUnits("1.0019", 36), 10);
      /**
       * supplierAmount  = 5e17
       * deltaIndex      = marketStoredIndex - userStoredIndex
       *                 = 1.0019e36 - 1e36 = 0.0019e36
       * suppliedAccrued+= supplierTokens * deltaIndex / 1e36
       *                 = 5e17 * 0.0019e36 / 1e36 = 0.00095e18
       */

      await someAuditor.distributeSupplierExa(exafin.address, mariaUser.address);
      let accrued = await someAuditor.getExaAccrued(mariaUser.address);
      let balance = await exaToken.balanceOf(mariaUser.address);
      expect(accrued).to.equal(parseUnits("0.00095"));
      expect(balance).to.equal(0);
    });

  });

});
