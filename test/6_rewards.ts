import { ethers } from "hardhat";
import { expect } from "chai";
import { Contract } from "ethers";
import {
  DefaultEnv,
  errorGeneric,
  ExactlyEnv,
  ProtocolError,
  RewardsLibEnv,
} from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("ExaToken", () => {
  let exactlyEnv: DefaultEnv;
  let rewardsLibEnv: RewardsLibEnv;

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

  let mariaUser: SignerWithAddress;
  let bobUser: SignerWithAddress;
  let owner: SignerWithAddress;

  beforeEach(async () => {
    exactlyEnv = await ExactlyEnv.create(mockedTokens);
    rewardsLibEnv = await ExactlyEnv.createRewardsEnv();
  });

  describe("Rewards", () => {
    let dai: Contract;
    let auditor: Contract;

    beforeEach(async () => {
      [owner, mariaUser, bobUser] = await ethers.getSigners();

      dai = exactlyEnv.getUnderlying("DAI");
      auditor = exactlyEnv.auditor;

      // From Owner to User
      await dai.transfer(mariaUser.address, parseUnits("1000"));
    });

    describe("setExaSpeed", () => {
      it("should revert if non admin access", async () => {
        await expect(
          auditor
            .connect(mariaUser)
            .setExaSpeed(exactlyEnv.getExafin("DAI").address, parseUnits("1"))
        ).to.be.revertedWith("AccessControl");
      });

      it("should revert if an invalid exafin address", async () => {
        await expect(
          auditor.setExaSpeed(exactlyEnv.notAnExafinAddress, parseUnits("1"))
        ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
      });
    });
  });

  describe("updateExaBorrowIndex", () => {
    let auditorHarness: Contract;
    let exafinHarness: Contract;

    beforeEach(async () => {
      auditorHarness = rewardsLibEnv.auditorHarness;
      exafinHarness = rewardsLibEnv.exafinHarness;
    });

    it("should calculate EXA borrower state index correctly", async () => {
      let amountBorrowWithCommission = parseUnits("55");
      let blocksDelta = 2;

      await exafinHarness.setTotalBorrows(amountBorrowWithCommission);

      // Call exaSpeed and jump blocksDelta
      await auditorHarness.setBlockNumber(0);
      await auditorHarness.setExaSpeed(
        exafinHarness.address,
        parseUnits("0.5")
      );
      await auditorHarness.setBlockNumber(blocksDelta);
      await auditorHarness.updateExaBorrowIndex(exafinHarness.address);
      const [newIndex] = await auditorHarness.getBorrowState(
        exafinHarness.address
      );
      /*
        exaAccrued = deltaBlocks * borrowSpeed
                    = 2 * 0.5e18 = 1e18
        newIndex   += 1e36 + (exaAccrued * 1e36 / borrowAmt(w commission))
                    = 1e36 + (5e18 * 1e36 / 0.5e18) = ~1.019e36
      */
      let exaAccruedDelta = parseUnits("0.5").mul(blocksDelta);
      let ratioDelta = exaAccruedDelta
        .mul(parseUnits("1", 36))
        .div(amountBorrowWithCommission);

      let newIndexCalculated = parseUnits("1", 36).add(ratioDelta);
      expect(newIndex).to.be.equal(newIndexCalculated);
    });

    it("should not update index if no blocks passed since last accrual", async () => {
      await auditorHarness.setBlockNumber(0);
      await auditorHarness.setExaSpeed(
        exafinHarness.address,
        parseUnits("0.5")
      );
      await exafinHarness.setTotalBorrows(parseUnits("10000"));
      await auditorHarness.updateExaBorrowIndex(exafinHarness.address);

      const [newIndex, block] = await auditorHarness.getBorrowState(
        exafinHarness.address
      );
      expect(newIndex).to.equal(parseUnits("1", 36));
      expect(block).to.equal(0);
    });

    it("should not update index if EXA speed is 0", async () => {
      // Update borrows
      await auditorHarness.setBlockNumber(0);
      await auditorHarness.setExaSpeed(
        exafinHarness.address,
        parseUnits("0.5")
      );
      await auditorHarness.setBlockNumber(100);
      await auditorHarness.setExaSpeed(exafinHarness.address, 0);
      await exafinHarness.setTotalBorrows(parseUnits("10000"));
      await auditorHarness.updateExaBorrowIndex(exafinHarness.address);

      const [newIndex, block] = await auditorHarness.getBorrowState(
        exafinHarness.address
      );
      expect(newIndex).to.equal(parseUnits("1", 36));
      expect(block).to.equal(100);
    });
  });

  describe("updateExaSupplyIndex", () => {
    let auditorHarness: Contract;
    let exafinHarness: Contract;

    beforeEach(async () => {
      auditorHarness = rewardsLibEnv.auditorHarness;
      exafinHarness = rewardsLibEnv.exafinHarness;
    });

    it("should calculate EXA supplier index correctly", async () => {
      let amountSupplyWithCommission = parseUnits("10");
      let blocksDelta = 100;

      // Call exaSpeed and jump blocksDelta
      await auditorHarness.setBlockNumber(0);
      await auditorHarness.setExaSpeed(
        exafinHarness.address,
        parseUnits("0.5")
      );
      await auditorHarness.setBlockNumber(blocksDelta);
      await exafinHarness.setTotalDeposits(amountSupplyWithCommission);
      await auditorHarness.updateExaSupplyIndex(exafinHarness.address);
      const [newIndex] = await auditorHarness.getSupplyState(
        exafinHarness.address
      );
      /*
        exaAccrued = deltaBlocks * borrowSpeed
                    = 100 * 0.5e18 = 50e18
        newIndex   += 1e36 + (exaAccrued * 1e36 / supplyWithCommission)
                    = 1e36 + (50-8 * 1e36 / 0.5e18) = ~1.019e36
      */
      let exaAccruedDelta = parseUnits("0.5").mul(blocksDelta);
      let ratioDelta = exaAccruedDelta
        .mul(parseUnits("1", 36))
        .div(amountSupplyWithCommission);

      let newIndexCalculated = parseUnits("1", 36).add(ratioDelta);
      expect(newIndex).to.be.equal(newIndexCalculated);
    });

    it("should not update index if no blocks passed since last accrual", async () => {
      await auditorHarness.setBlockNumber(0);
      await auditorHarness.setExaSpeed(
        exafinHarness.address,
        parseUnits("0.5")
      );
      await exafinHarness.setTotalDeposits(parseUnits("10000"));
      await auditorHarness.updateExaSupplyIndex(exafinHarness.address);

      const [newIndex, block] = await auditorHarness.getSupplyState(
        exafinHarness.address
      );
      expect(newIndex).to.equal(parseUnits("1", 36));
      expect(block).to.equal(0);
    });

    it("should not update index if EXA speed is 0", async () => {
      // Update borrows
      await auditorHarness.setBlockNumber(0);
      await auditorHarness.setExaSpeed(
        exafinHarness.address,
        parseUnits("0.5")
      );
      await auditorHarness.setBlockNumber(100);
      await auditorHarness.setExaSpeed(exafinHarness.address, 0);
      await exafinHarness.setTotalDeposits(parseUnits("10000"));
      await auditorHarness.updateExaSupplyIndex(exafinHarness.address);

      const [newIndex, block] = await auditorHarness.getSupplyState(
        exafinHarness.address
      );
      expect(newIndex).to.equal(parseUnits("1", 36));
      expect(block).to.equal(100);
    });
  });

  describe("distributeBorrowerExa", () => {
    let auditorHarness: Contract;
    let exafinHarness: Contract;
    let exaToken: Contract;

    beforeEach(async () => {
      auditorHarness = rewardsLibEnv.auditorHarness;
      exafinHarness = rewardsLibEnv.exafinHarness;
      exaToken = rewardsLibEnv.exaToken;
    });

    it("should update borrow index checkpoint but not exaAccrued for first time user", async () => {
      let borrowIndex = parseUnits("6", 36);
      await auditorHarness.setExaBorrowState(
        exafinHarness.address,
        borrowIndex,
        10
      );

      await exafinHarness.setTotalBorrows(parseUnits("10000"));
      await exafinHarness.setBorrowsOf(owner.address, parseUnits("100"));

      await auditorHarness.distributeBorrowerExa(
        exafinHarness.address,
        owner.address
      );

      expect(await auditorHarness.getExaAccrued(owner.address)).to.equal(0);
      const [newIndex] = await auditorHarness.getBorrowState(
        exafinHarness.address
      );
      expect(newIndex).to.equal(borrowIndex);
    });

    it("should transfer EXA and update borrow index checkpoint correctly for repeat time user", async () => {
      await exaToken.transfer(auditorHarness.address, parseUnits("50"));
      await exafinHarness.setBorrowsOf(mariaUser.address, parseUnits("5"));
      await auditorHarness.setExaBorrowState(
        exafinHarness.address,
        parseUnits("6", 36),
        10
      );
      await auditorHarness.setExaBorrowerIndex(
        exafinHarness.address,
        mariaUser.address,
        parseUnits("1", 36)
      );
      /**
       * this tests that an acct with half the total borrows over that time gets 25e18 EXA
       * borrowerAmount = 5e18
       * deltaIndex     = marketStoredIndex - userStoredIndex
       *                = 6e36 - 1e36 = 5e36
       * borrowerAccrued= borrowerAmount * deltaIndex / 1e36
       *                = 5e18 * 5e36 / 1e36 = 25e18
       */
      let tx = await auditorHarness.distributeBorrowerExa(
        exafinHarness.address,
        mariaUser.address
      );
      let accrued = await auditorHarness.getExaAccrued(mariaUser.address);

      expect(accrued).to.equal(parseUnits("25"));
      expect(await exaToken.balanceOf(mariaUser.address)).to.equal(0);
      expect(tx)
        .to.emit(auditorHarness, "DistributedBorrowerExa")
        .withArgs(
          exafinHarness.address,
          mariaUser.address,
          parseUnits("25"),
          parseUnits("6", 36)
        );
    });

    it("should not transfer EXA automatically", async () => {
      await exaToken.transfer(auditorHarness.address, parseUnits("50"));
      await exafinHarness.setBorrowsOf(mariaUser.address, parseUnits("0.5"));
      await auditorHarness.setExaBorrowState(
        exafinHarness.address,
        parseUnits("1.0019", 36),
        10
      );
      await auditorHarness.setExaBorrowerIndex(
        exafinHarness.address,
        mariaUser.address,
        parseUnits("1", 36)
      );
      /*
       * borrowerAmount =  5e17
       * deltaIndex     = marketStoredIndex - userStoredIndex
       *                = 1.0019e36 - 1e36 = 0.0019e36
       * borrowerAccrued= borrowerAmount * deltaIndex / 1e36
       *                = 5e17 * 0.0019e36 / 1e36 = 0.00095e18
       */
      await auditorHarness.distributeBorrowerExa(
        exafinHarness.address,
        mariaUser.address
      );
      let accrued = await auditorHarness.getExaAccrued(mariaUser.address);

      expect(accrued).to.equal(parseUnits("0.00095"));
      expect(await exaToken.balanceOf(mariaUser.address)).to.equal(0);
    });
  });

  describe("distributeSupplierExa", () => {
    let auditorHarness: Contract;
    let exafinHarness: Contract;
    let exaToken: Contract;

    beforeEach(async () => {
      auditorHarness = rewardsLibEnv.auditorHarness;
      exafinHarness = rewardsLibEnv.exafinHarness;
      exaToken = rewardsLibEnv.exaToken;
    });

    it("should transfer EXA and update supply index correctly for first time user", async () => {
      await exaToken.transfer(auditorHarness.address, parseUnits("50"));
      await exafinHarness.setSuppliesOf(mariaUser.address, parseUnits("5"));
      await auditorHarness.setExaSupplyState(
        exafinHarness.address,
        parseUnits("6", 36),
        10
      );
      /**
       * 100 delta blocks, 10e18 total supply, 0.5e18 supplySpeed => 6e18 exaSupplyIndex
       * confirming an acct with half the total supply over that time gets 25e18 EXA:
       * supplierAmount  = 5e18
       * deltaIndex      = marketStoredIndex - userStoredIndex
       *                 = 6e36 - 1e36 = 5e36
       * suppliedAccrued+= supplierTokens * deltaIndex / 1e36
       *                 = 5e18 * 5e36 / 1e36 = 25e18
       */
      let tx = await auditorHarness.distributeAllSupplierExa(
        exafinHarness.address,
        mariaUser.address
      );
      let accrued = await auditorHarness.getExaAccrued(mariaUser.address);
      let balance = await exaToken.balanceOf(mariaUser.address);
      expect(accrued).to.equal(0);
      expect(balance).to.equal(parseUnits("25"));
      expect(tx)
        .to.emit(auditorHarness, "DistributedSupplierExa")
        .withArgs(
          exafinHarness.address,
          mariaUser.address,
          parseUnits("25"),
          parseUnits("6", 36)
        );
    });

    it("should update EXA accrued and supply index for repeat user", async () => {
      await exaToken.transfer(auditorHarness.address, parseUnits("50"));
      await exafinHarness.setSuppliesOf(mariaUser.address, parseUnits("5"));
      await auditorHarness.setExaSupplyState(
        exafinHarness.address,
        parseUnits("6", 36),
        10
      );
      await auditorHarness.setExaSupplierIndex(
        exafinHarness.address,
        mariaUser.address,
        parseUnits("2", 36)
      );
      /**
       * supplierAmount  = 5e18
       * deltaIndex      = marketStoredIndex - userStoredIndex
       *                 = 6e36 - 2e36 = 4e36
       * suppliedAccrued+= supplierTokens * deltaIndex / 1e36
       *                 = 5e18 * 4e36 / 1e36 = 20e18
       */
      await auditorHarness.distributeAllSupplierExa(
        exafinHarness.address,
        mariaUser.address
      );
      let accrued = await auditorHarness.getExaAccrued(mariaUser.address);
      let balance = await exaToken.balanceOf(mariaUser.address);
      expect(accrued).to.equal(0);
      expect(balance).to.equal(parseUnits("20"));
    });

    it("should not transfer EXA automatically", async () => {
      await exaToken.transfer(auditorHarness.address, parseUnits("50"));
      await exafinHarness.setSuppliesOf(mariaUser.address, parseUnits("0.5"));
      await auditorHarness.setExaSupplyState(
        exafinHarness.address,
        parseUnits("1.0019", 36),
        10
      );
      /**
       * supplierAmount  = 5e17
       * deltaIndex      = marketStoredIndex - userStoredIndex
       *                 = 1.0019e36 - 1e36 = 0.0019e36
       * suppliedAccrued+= supplierTokens * deltaIndex / 1e36
       *                 = 5e17 * 0.0019e36 / 1e36 = 0.00095e18
       */
      await auditorHarness.distributeSupplierExa(
        exafinHarness.address,
        mariaUser.address
      );
      let accrued = await auditorHarness.getExaAccrued(mariaUser.address);
      let balance = await exaToken.balanceOf(mariaUser.address);
      expect(accrued).to.equal(parseUnits("0.00095"));
      expect(balance).to.equal(0);
    });
  });

  describe("grantExa", () => {
    let auditorHarness: Contract;
    let exaToken: Contract;

    beforeEach(async () => {
      auditorHarness = rewardsLibEnv.auditorHarness;
      exaToken = rewardsLibEnv.exaToken;
    });

    it("should not transfer EXA if EXA accrued is greater than EXA remaining", async () => {
      const exaRemaining = 99;
      const mariaUserAccruedPre = 100;
      let balancePre = await exaToken.balanceOf(mariaUser.address);
      await exaToken.transfer(auditorHarness.address, exaRemaining);
      await auditorHarness.setExaAccrued(
        mariaUser.address,
        mariaUserAccruedPre
      );

      await auditorHarness.grantExa(mariaUser.address, mariaUserAccruedPre);

      let balancePost = await exaToken.balanceOf(mariaUser.address);
      expect(balancePre).to.equal(0);
      expect(balancePost).to.equal(0);
    });
  });

  describe("claimExa", () => {
    let auditorHarness: Contract;
    let auditor: Contract;
    let exafinHarness: Contract;
    let exaToken: Contract;

    beforeEach(async () => {
      exafinHarness = rewardsLibEnv.exafinHarness;
      auditor = exactlyEnv.auditor;
      auditorHarness = rewardsLibEnv.auditorHarness;
      exaToken = rewardsLibEnv.exaToken;
    });

    it("should revert when a market is not listed", async () => {
      await expect(
        auditor.claimExa(mariaUser.address, [exactlyEnv.notAnExafinAddress])
      ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
    });

    it("should accrue EXA and then transfer EXA accrued", async () => {
      const exaRemaining = parseUnits("1000000");
      const mintAmount = parseUnits("12");
      const deltaBlocks = 10;
      const exaSpeed = parseUnits("1");
      await exaToken.transfer(auditorHarness.address, exaRemaining);

      await auditorHarness.setBlockNumber(parseUnits("2", 7));
      await auditorHarness.setExaSpeed(
        exafinHarness.address,
        parseUnits("0.5")
      );
      await auditorHarness.refreshIndexes(exafinHarness.address);
      await auditorHarness.setExaSpeed(exafinHarness.address, exaSpeed);

      const bobAccruedPre = await auditorHarness.getExaAccrued(
        exafinHarness.address
      );
      const bobBalancePre = await exaToken.balanceOf(bobUser.address);

      await exafinHarness.setTotalDeposits(mintAmount);
      await exafinHarness.setSuppliesOf(bobUser.address, mintAmount);
      await auditorHarness.setBlockNumber(parseUnits("2", 7).add(10));

      await auditorHarness.claimExaAll(bobUser.address);
      const bobAccruedPost = await auditorHarness.getExaAccrued(
        bobUser.address
      );
      const bobBalancePost = await exaToken.balanceOf(bobUser.address);

      expect(bobAccruedPre).to.equal(0);
      expect(bobAccruedPost).to.equal(0);
      expect(bobBalancePre).to.equal(0);
      expect(bobBalancePost).to.equal(exaSpeed.mul(deltaBlocks).sub(1));
    });
  });
});
