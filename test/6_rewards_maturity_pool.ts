import { ethers } from "hardhat";
import { expect } from "chai";
import { Contract } from "ethers";
import {
  DefaultEnv,
  errorGeneric,
  ExactlyEnv,
  ExaTime,
  ProtocolError,
  RewardsLibEnv,
} from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("ExaToken", () => {
  let exactlyEnv: DefaultEnv;
  let rewardsLibEnv: RewardsLibEnv;
  let exaTime: ExaTime = new ExaTime();
  let snapshot: any;

  let mariaUser: SignerWithAddress;
  let bobUser: SignerWithAddress;
  let owner: SignerWithAddress;
  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    exactlyEnv = await ExactlyEnv.create({});
    rewardsLibEnv = await ExactlyEnv.createRewardsEnv();
    [owner, mariaUser, bobUser] = await ethers.getSigners();
  });

  describe("Integration", () => {
    let dai: Contract;
    let fixedLenderDAI: Contract;
    let auditor: Contract;
    let exaToken: Contract;

    beforeEach(async () => {
      dai = exactlyEnv.getUnderlying("DAI");
      fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
      auditor = exactlyEnv.auditor;
      exaToken = exactlyEnv.exaToken;

      // From Owner to User
      await dai.transfer(mariaUser.address, parseUnits("1000"));
    });

    describe("setExaSpeed", () => {
      it("should revert if non admin access", async () => {
        await expect(
          auditor
            .connect(mariaUser)
            .setExaSpeed(
              exactlyEnv.getFixedLender("DAI").address,
              parseUnits("1")
            )
        ).to.be.revertedWith("AccessControl");
      });

      it("should revert if an invalid fixedLender address", async () => {
        await expect(
          auditor.setExaSpeed(
            exactlyEnv.notAnFixedLenderAddress,
            parseUnits("1")
          )
        ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
      });

      it("should emit ExaSpeedUpdated if speed changes", async () => {
        await expect(
          auditor.setExaSpeed(
            exactlyEnv.getFixedLender("DAI").address,
            parseUnits("1")
          )
        ).to.emit(auditor, "ExaSpeedUpdated");
      });

      it("should NOT emit ExaSpeedUpdated if speed doesn't change", async () => {
        await auditor.setExaSpeed(
          exactlyEnv.getFixedLender("DAI").address,
          parseUnits("1")
        );

        await expect(
          auditor.setExaSpeed(
            exactlyEnv.getFixedLender("DAI").address,
            parseUnits("1")
          )
        ).to.not.emit(auditor, "ExaSpeedUpdated");
      });
    });

    describe("FixedLender-Auditor-ExaLib integration", () => {
      beforeEach(async () => {
        await auditor.setExaSpeed(fixedLenderDAI.address, parseUnits("0.5"));
        await dai.transfer(mariaUser.address, parseUnits("1000"));
        await exaToken.transfer(auditor.address, parseUnits("50"));
      });

      it("should retrieve all rewards when calling claimExaAll", async () => {
        const underlyingAmount = parseUnits("100");
        await dai
          .connect(mariaUser)
          .approve(fixedLenderDAI.address, underlyingAmount);

        let balanceUserPre = await exaToken
          .connect(mariaUser)
          .balanceOf(mariaUser.address);

        await expect(
          fixedLenderDAI
            .connect(mariaUser)
            .depositToMaturityPool(underlyingAmount, exaTime.nextPoolID())
        ).to.emit(auditor, "DistributedMPSupplierExa");

        await auditor.connect(mariaUser).claimExaAll(mariaUser.address);

        let balanceUserPost = await exaToken
          .connect(mariaUser)
          .balanceOf(mariaUser.address);

        expect(balanceUserPre).to.equal(0);
        expect(balanceUserPost).to.not.equal(0);
      });

      it("should DistributedMPSupplierExa when supplying", async () => {
        const underlyingAmount = parseUnits("100");
        await dai.approve(fixedLenderDAI.address, underlyingAmount);

        await expect(
          fixedLenderDAI.depositToMaturityPool(
            underlyingAmount,
            exaTime.nextPoolID()
          )
        ).to.emit(auditor, "DistributedMPSupplierExa");
      });

      it("should DistributedMPBorrowerExa when borrowing on second interaction", async () => {
        const underlyingAmount = parseUnits("100");
        await dai.approve(fixedLenderDAI.address, underlyingAmount);
        await fixedLenderDAI.depositToMaturityPool(
          underlyingAmount,
          exaTime.nextPoolID()
        );

        await expect(
          fixedLenderDAI.borrowFromMaturityPool(
            underlyingAmount.div(4),
            exaTime.nextPoolID()
          )
        ).to.not.emit(auditor, "DistributedMPBorrowerExa");

        await expect(
          fixedLenderDAI.borrowFromMaturityPool(
            underlyingAmount.div(4),
            exaTime.nextPoolID()
          )
        ).to.emit(auditor, "DistributedMPBorrowerExa");
      });

      it("should DistributedMPSupplierExa when redeeming deposit", async () => {
        // connect through Maria
        let fixedLenderMaria = fixedLenderDAI.connect(mariaUser);
        let underlyingTokenUser = dai.connect(mariaUser);
        let depositAmount = parseUnits("1");

        // deposit some money to a maturity and parse event
        await underlyingTokenUser.approve(
          fixedLenderMaria.address,
          depositAmount
        );
        await fixedLenderMaria.depositToMaturityPool(
          depositAmount,
          exaTime.nextPoolID()
        );

        // Move in time to maturity
        await ethers.provider.send("evm_setNextBlockTimestamp", [
          exaTime.nextPoolID(),
        ]);
        await ethers.provider.send("evm_mine", []);

        await expect(
          fixedLenderMaria.withdrawFromMaturityPool(
            mariaUser.address,
            depositAmount,
            exaTime.nextPoolID()
          )
        ).to.emit(auditor, "DistributedMPSupplierExa");
      });

      it("should DistributedMPBorrowerExa when repaying debt", async () => {
        // connect through Maria
        let fixedLenderMaria = fixedLenderDAI.connect(mariaUser);
        let underlyingTokenUser = dai.connect(mariaUser);
        let underlyingAmount = parseUnits("100");

        await underlyingTokenUser.approve(
          fixedLenderDAI.address,
          underlyingAmount
        );
        // deposit some money and parse event
        await fixedLenderMaria.depositToMaturityPool(
          underlyingAmount.div(2),
          exaTime.nextPoolID()
        );
        await fixedLenderMaria.borrowFromMaturityPool(
          underlyingAmount.div(4),
          exaTime.nextPoolID()
        );

        // Move in time to maturity
        await ethers.provider.send("evm_setNextBlockTimestamp", [
          exaTime.nextPoolID(),
        ]);
        await ethers.provider.send("evm_mine", []);

        // repay and succeed
        await expect(
          fixedLenderMaria.repayToMaturityPool(
            mariaUser.address,
            exaTime.nextPoolID(),
            underlyingAmount.div(4)
          )
        ).to.emit(auditor, "DistributedMPBorrowerExa");
      });
    });
  });

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
      expect(newIndex).to.equal(parseUnits("1", 36));
      expect(block).to.equal(100);
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
      await fixedLenderHarness.setTotalMpDeposits(amountSupplyWithCommission);
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
      await fixedLenderHarness.setTotalMpDeposits(parseUnits("10000"));
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
      await fixedLenderHarness.setTotalMpDeposits(parseUnits("10000"));
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
      await fixedLenderHarness.setTotalMpBorrowsUser(
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
      await fixedLenderHarness.setTotalMpBorrowsUser(
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
      await fixedLenderHarness.setTotalMpBorrowsUser(
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
      await fixedLenderHarness.setTotalMpDepositsUser(
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
      let tx = await auditorHarness.distributeAllSupplierExa(
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
      await fixedLenderHarness.setTotalMpDepositsUser(
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
      await auditorHarness.distributeAllSupplierExa(
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
      await fixedLenderHarness.setTotalMpDepositsUser(
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

      await fixedLenderHarness.setTotalMpDeposits(mintAmount);
      await fixedLenderHarness.setTotalMpDepositsUser(
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
  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
