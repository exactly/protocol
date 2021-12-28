import { ethers } from "hardhat";
import { expect } from "chai";
import { BigNumber, Contract } from "ethers";
import {
  errorGeneric,
  ExactlyEnv,
  ExaTime,
  ProtocolError,
  RewardsLibEnv,
} from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv } from "./defaultEnv";

describe("ExaToken", () => {
  let exactlyEnv: DefaultEnv;
  let rewardsLibEnv: RewardsLibEnv;
  let exaTime: ExaTime = new ExaTime();

  let mariaUser: SignerWithAddress;
  let bobUser: SignerWithAddress;
  let owner: SignerWithAddress;
  let exaToken: Contract;
  let snapshot: any;

  beforeEach(async () => {
    exactlyEnv = await ExactlyEnv.create({});
    rewardsLibEnv = await ExactlyEnv.createRewardsEnv();
    [owner, mariaUser, bobUser] = await ethers.getSigners();
    exaToken = exactlyEnv.exaToken;
    snapshot = await exactlyEnv.takeSnapshot();
  });

  describe("FixedLender-Auditor-ExaLib integration", () => {
    describe("GIVEN a 0.5 EXA distribution per block and Auditor having 5000 EXA in their power", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(owner);
        await exactlyEnv.transfer("DAI", mariaUser, "10000");
        await exaToken.transfer(exactlyEnv.auditor.address, parseUnits("5000"));
        await exactlyEnv.setExaSpeed("DAI", "0.5");
        exactlyEnv.switchWallet(mariaUser);
      });

      describe("WHEN maria deposits to a Maturity Pool", async () => {
        let balanceMariaPre: BigNumber;
        let tx: any;
        beforeEach(async () => {
          balanceMariaPre = await exaToken
            .connect(mariaUser)
            .balanceOf(mariaUser.address);

          tx = exactlyEnv.depositMP("DAI", exaTime.nextPoolID(), "100");
        });

        it("THEN the auditor contract should emit DistributedMPSupplierExa", async () => {
          expect(tx).to.emit(exactlyEnv.auditor, "DistributedMPSupplierExa");
        });

        it("THEN maria pre-balance should be 0", async () => {
          await tx;
          expect(balanceMariaPre).to.equal(0);
        });

        it("THEN maria post-balance should be more than 0", async () => {
          await tx;
          await exactlyEnv.claimAllEXA(mariaUser.address);

          const balanceMariaPost = await exaToken
            .connect(mariaUser)
            .balanceOf(mariaUser.address);

          expect(balanceMariaPost).to.not.equal(0);
        });
      });

      describe("AND GIVEN that maria makes a second deposit of 100 DAI and also borrows 25 DAI two times", () => {
        let txBorrow1: any;
        let txBorrow2: any;
        beforeEach(async () => {
          await exactlyEnv.depositMP("DAI", exaTime.nextPoolID(), "100");
          txBorrow1 = exactlyEnv.borrowMP("DAI", exaTime.nextPoolID(), "25");
          txBorrow2 = exactlyEnv.borrowMP("DAI", exaTime.nextPoolID(), "25");
        });

        it("THEN the first borrow should've NOT emitted DistributedMPBorrowerExa", async () => {
          await expect(txBorrow1).to.not.emit(
            exactlyEnv.auditor,
            "DistributedMPBorrowerExa"
          );
        });

        it("THEN the second borrow should've emitted DistributedMPBorrowerExa", async () => {
          await expect(txBorrow2).to.emit(
            exactlyEnv.auditor,
            "DistributedMPBorrowerExa"
          );
        });
      });

      describe("AND GIVEN that maria deposits 100 DAI and withdraws at maturity the 100 DAI", () => {
        let tx: any;
        beforeEach(async () => {
          await exactlyEnv.depositMP("DAI", exaTime.nextPoolID(), "100");
          await exactlyEnv.moveInTime(exaTime.nextPoolID());
          tx = exactlyEnv.withdrawMP("DAI", exaTime.nextPoolID(), "100");
        });

        it("THEN the auditor should distribute EXA and emit DistributedMPSupplierExa", async () => {
          await expect(tx).to.emit(
            exactlyEnv.auditor,
            "DistributedMPSupplierExa"
          );
        });
      });

      describe("AND GIVEN that maria borrows 100 DAI and repays at maturity the 100 DAI", () => {
        let tx: any;
        beforeEach(async () => {
          await exactlyEnv.depositMP("DAI", exaTime.nextPoolID(), "150");
          await exactlyEnv.borrowMP("DAI", exaTime.nextPoolID(), "100");
          await exactlyEnv.moveInTime(exaTime.nextPoolID());
          tx = exactlyEnv.repayMP("DAI", exaTime.nextPoolID(), "100");
        });

        it("THEN the auditor should distribute EXA and emit DistributedMPBorrowerExa", async () => {
          await expect(tx).to.emit(
            exactlyEnv.auditor,
            "DistributedMPBorrowerExa"
          );
        });
      });
      afterEach(async () => {
        await exactlyEnv.revertSnapshot(snapshot);
      });
    });
  });

  describe("ExaLib unit tests", () => {
    describe("updateExaMPBorrowIndex", () => {
      let auditorHarness: Contract;
      let fixedLenderHarness: Contract;

      beforeEach(async () => {
        auditorHarness = rewardsLibEnv.auditorHarness;
        fixedLenderHarness = rewardsLibEnv.fixedLenderHarness;
      });

      it("should calculate EXA maturity pool borrow index correctly", async () => {
        let amountBorrowWithCommission = parseUnits("55");
        let blocksDelta = 2;

        await fixedLenderHarness.setTotalMpBorrows(amountBorrowWithCommission);

        // Call exaSpeed and jump blocksDelta
        await auditorHarness.setBlockNumber(0);
        await auditorHarness.setExaSpeed(
          fixedLenderHarness.address,
          parseUnits("0.5")
        );
        await auditorHarness.setBlockNumber(blocksDelta);
        await auditorHarness.updateExaMPBorrowIndex(fixedLenderHarness.address);
        const [newIndex] = await auditorHarness.getBorrowState(
          fixedLenderHarness.address
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

      it("should not update maturity pool borrow index if no blocks passed since last accrual", async () => {
        await auditorHarness.setBlockNumber(0);
        await auditorHarness.setExaSpeed(
          fixedLenderHarness.address,
          parseUnits("0.5")
        );
        await fixedLenderHarness.setTotalMpBorrows(parseUnits("10000"));
        await auditorHarness.updateExaMPBorrowIndex(fixedLenderHarness.address);

        const [newIndex, block] = await auditorHarness.getBorrowState(
          fixedLenderHarness.address
        );
        expect(newIndex).to.equal(parseUnits("1", 36));
        expect(block).to.equal(0);
      });

      it("should not update maturity pool borrow index if EXA speed is 0", async () => {
        // Update borrows
        await auditorHarness.setBlockNumber(0);
        await auditorHarness.setExaSpeed(
          fixedLenderHarness.address,
          parseUnits("0.5")
        );
        await auditorHarness.setBlockNumber(100);
        await auditorHarness.setExaSpeed(fixedLenderHarness.address, 0);
        await fixedLenderHarness.setTotalMpBorrows(parseUnits("10000"));
        await auditorHarness.updateExaMPBorrowIndex(fixedLenderHarness.address);

        const [newIndex, block] = await auditorHarness.getBorrowState(
          fixedLenderHarness.address
        );
        expect(block).to.equal(100);
        expect(newIndex).to.equal(parseUnits("1", 36));
      });
    });

    describe("updateExaMPSupplyIndex", () => {
      let auditorHarness: Contract;
      let fixedLenderHarness: Contract;

      beforeEach(async () => {
        auditorHarness = rewardsLibEnv.auditorHarness;
        fixedLenderHarness = rewardsLibEnv.fixedLenderHarness;
      });

      it("should calculate EXA maturity pool supply index correctly", async () => {
        let amountSupplyWithCommission = parseUnits("10");
        let blocksDelta = 100;

        // Call exaSpeed and jump blocksDelta
        await auditorHarness.setBlockNumber(0);
        await auditorHarness.setExaSpeed(
          fixedLenderHarness.address,
          parseUnits("0.5")
        );
        await auditorHarness.setBlockNumber(blocksDelta);
        await fixedLenderHarness.setTotalMPDeposits(amountSupplyWithCommission);
        await auditorHarness.updateExaMPSupplyIndex(fixedLenderHarness.address);
        const [newIndex] = await auditorHarness.getMaturitySupplyState(
          fixedLenderHarness.address
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

      it("should not update maturity pool supply index if no blocks passed since last accrual", async () => {
        await auditorHarness.setBlockNumber(0);
        await auditorHarness.setExaSpeed(
          fixedLenderHarness.address,
          parseUnits("0.5")
        );
        await fixedLenderHarness.setTotalMPDeposits(parseUnits("10000"));
        await auditorHarness.updateExaMPSupplyIndex(fixedLenderHarness.address);

        const [newIndex, block] = await auditorHarness.getMaturitySupplyState(
          fixedLenderHarness.address
        );
        expect(newIndex).to.equal(parseUnits("1", 36));
        expect(block).to.equal(0);
      });

      it("should not update maturity pool supply index if EXA speed is 0", async () => {
        // Update borrows
        await auditorHarness.setBlockNumber(0);
        await auditorHarness.setExaSpeed(
          fixedLenderHarness.address,
          parseUnits("0.5")
        );
        await auditorHarness.setBlockNumber(100);
        await auditorHarness.setExaSpeed(fixedLenderHarness.address, 0);
        await fixedLenderHarness.setTotalMPDeposits(parseUnits("10000"));
        await auditorHarness.updateExaMPSupplyIndex(fixedLenderHarness.address);

        const [newIndex, block] = await auditorHarness.getMaturitySupplyState(
          fixedLenderHarness.address
        );
        expect(newIndex).to.equal(parseUnits("1", 36));
        expect(block).to.equal(100);
      });
    });

    describe("distributeMPBorrowerExa", () => {
      let auditorHarness: Contract;
      let fixedLenderHarness: Contract;
      let exaToken: Contract;

      beforeEach(async () => {
        auditorHarness = rewardsLibEnv.auditorHarness;
        fixedLenderHarness = rewardsLibEnv.fixedLenderHarness;
        exaToken = rewardsLibEnv.exaToken;
      });

      it("should update maturity borrow index checkpoint but not exaAccrued for first time user", async () => {
        let borrowIndex = parseUnits("6", 36);
        await auditorHarness.setExaMPBorrowState(
          fixedLenderHarness.address,
          borrowIndex,
          10
        );

        await fixedLenderHarness.setTotalMpBorrows(parseUnits("10000"));
        await fixedLenderHarness.setTotalMPBorrowsUser(
          owner.address,
          parseUnits("100")
        );

        await auditorHarness.distributeMPBorrowerExa(
          fixedLenderHarness.address,
          owner.address
        );

        expect(await auditorHarness.getExaAccrued(owner.address)).to.equal(0);
        const [newIndex] = await auditorHarness.getBorrowState(
          fixedLenderHarness.address
        );
        expect(newIndex).to.equal(borrowIndex);
      });

      it("should transfer EXA and update maturity borrow index checkpoint correctly for repeat time user", async () => {
        await exaToken.transfer(auditorHarness.address, parseUnits("50"));
        await fixedLenderHarness.setTotalMPBorrowsUser(
          mariaUser.address,
          parseUnits("5")
        );
        await auditorHarness.setExaMPBorrowState(
          fixedLenderHarness.address,
          parseUnits("6", 36),
          10
        );
        await auditorHarness.setExaMPBorrowerIndex(
          fixedLenderHarness.address,
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
        let tx = await auditorHarness.distributeMPBorrowerExa(
          fixedLenderHarness.address,
          mariaUser.address
        );
        let accrued = await auditorHarness.getExaAccrued(mariaUser.address);

        expect(accrued).to.equal(parseUnits("25"));
        expect(await exaToken.balanceOf(mariaUser.address)).to.equal(0);
        expect(tx)
          .to.emit(auditorHarness, "DistributedMPBorrowerExa")
          .withArgs(
            fixedLenderHarness.address,
            mariaUser.address,
            parseUnits("25"),
            parseUnits("6", 36)
          );
      });

      it("should not transfer EXA automatically", async () => {
        await exaToken.transfer(auditorHarness.address, parseUnits("50"));
        await fixedLenderHarness.setTotalMPBorrowsUser(
          mariaUser.address,
          parseUnits("0.5")
        );
        await auditorHarness.setExaMPBorrowState(
          fixedLenderHarness.address,
          parseUnits("1.0019", 36),
          10
        );
        await auditorHarness.setExaMPBorrowerIndex(
          fixedLenderHarness.address,
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
        await auditorHarness.distributeMPBorrowerExa(
          fixedLenderHarness.address,
          mariaUser.address
        );
        let accrued = await auditorHarness.getExaAccrued(mariaUser.address);

        expect(accrued).to.equal(parseUnits("0.00095"));
        expect(await exaToken.balanceOf(mariaUser.address)).to.equal(0);
      });
    });

    describe("distributeMPSupplierExa", () => {
      let auditorHarness: Contract;
      let fixedLenderHarness: Contract;
      let exaToken: Contract;

      beforeEach(async () => {
        auditorHarness = rewardsLibEnv.auditorHarness;
        fixedLenderHarness = rewardsLibEnv.fixedLenderHarness;
        exaToken = rewardsLibEnv.exaToken;
      });

      it("should transfer EXA and update maturity supplier index correctly for first time user", async () => {
        await exaToken.transfer(auditorHarness.address, parseUnits("50"));
        await fixedLenderHarness.setTotalMPDepositsUser(
          mariaUser.address,
          parseUnits("5")
        );
        await auditorHarness.setExaMPSupplyState(
          fixedLenderHarness.address,
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
        let tx = await auditorHarness.distributeAllMPSupplierExa(
          fixedLenderHarness.address,
          mariaUser.address
        );
        let accrued = await auditorHarness.getExaAccrued(mariaUser.address);
        let balance = await exaToken.balanceOf(mariaUser.address);
        expect(accrued).to.equal(0);
        expect(balance).to.equal(parseUnits("25"));
        expect(tx)
          .to.emit(auditorHarness, "DistributedMPSupplierExa")
          .withArgs(
            fixedLenderHarness.address,
            mariaUser.address,
            parseUnits("25"),
            parseUnits("6", 36)
          );
      });

      it("should update EXA accrued and maturity supplier index for repeat user", async () => {
        await exaToken.transfer(auditorHarness.address, parseUnits("50"));
        await fixedLenderHarness.setTotalMPDepositsUser(
          mariaUser.address,
          parseUnits("5")
        );
        await auditorHarness.setExaMPSupplyState(
          fixedLenderHarness.address,
          parseUnits("6", 36),
          10
        );
        await auditorHarness.setExaMPSupplierIndex(
          fixedLenderHarness.address,
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
        await auditorHarness.distributeAllMPSupplierExa(
          fixedLenderHarness.address,
          mariaUser.address
        );
        let accrued = await auditorHarness.getExaAccrued(mariaUser.address);
        let balance = await exaToken.balanceOf(mariaUser.address);
        expect(accrued).to.equal(0);
        expect(balance).to.equal(parseUnits("20"));
      });

      it("should not transfer EXA automatically", async () => {
        await exaToken.transfer(auditorHarness.address, parseUnits("50"));
        await fixedLenderHarness.setTotalMPDepositsUser(
          mariaUser.address,
          parseUnits("0.5")
        );
        await auditorHarness.setExaMPSupplyState(
          fixedLenderHarness.address,
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
        await auditorHarness.distributeMPSupplierExa(
          fixedLenderHarness.address,
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

      it("should transfer EXA if EXA accrued is greater than EXA remaining", async () => {
        const exaRemaining = 100;
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
        expect(balancePost).to.equal(exaRemaining);
      });
    });

    describe("claimExa", () => {
      let auditorHarness: Contract;
      let auditor: Contract;
      let fixedLenderHarness: Contract;
      let exaToken: Contract;

      beforeEach(async () => {
        fixedLenderHarness = rewardsLibEnv.fixedLenderHarness;
        auditor = exactlyEnv.auditor;
        auditorHarness = rewardsLibEnv.auditorHarness;
        exaToken = rewardsLibEnv.exaToken;
      });

      it("should revert when a market is not listed", async () => {
        await expect(
          auditor.claimExa(mariaUser.address, [
            exactlyEnv.notAnFixedLenderAddress,
          ])
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
          fixedLenderHarness.address,
          parseUnits("0.5")
        );
        await auditorHarness.refreshIndexes(fixedLenderHarness.address);
        await auditorHarness.setExaSpeed(fixedLenderHarness.address, exaSpeed);

        const bobAccruedPre = await auditorHarness.getExaAccrued(
          fixedLenderHarness.address
        );
        const bobBalancePre = await exaToken.balanceOf(bobUser.address);

        await fixedLenderHarness.setTotalMPDeposits(mintAmount);
        await fixedLenderHarness.setTotalMPDepositsUser(
          bobUser.address,
          mintAmount
        );
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
});
