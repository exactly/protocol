import { ethers } from "hardhat";
import { expect } from "chai";
import { Contract, BigNumber } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv } from "./defaultEnv";
import { RewardsLibEnv } from "./rewardsLibEnv";

describe("ExaToken Smart Pool", () => {
  let exactlyEnv: DefaultEnv;
  let rewardsLibEnv: RewardsLibEnv;
  let snapshot: any;
  let mariaUser: SignerWithAddress;
  let bobUser: SignerWithAddress;

  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  describe("FixedLender-Auditor-ExaLib integration", () => {
    let dai: Contract;
    let eDAI: Contract;
    let fixedLenderDAI: Contract;
    let auditor: Contract;
    let exaToken: Contract;

    before(async () => {
      exactlyEnv = await DefaultEnv.create({});
      dai = exactlyEnv.getUnderlying("DAI");
      eDAI = exactlyEnv.getEToken("DAI");
      fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
      auditor = exactlyEnv.auditor;
      exaToken = exactlyEnv.exaToken;
      [, mariaUser, bobUser] = await ethers.getSigners();

      // From Owner to User
      await dai.transfer(mariaUser.address, parseUnits("1000"));
    });

    describe("GIVEN maria has DAI in her balance", () => {
      beforeEach(async () => {
        await auditor.setExaSpeed(fixedLenderDAI.address, parseUnits("0.5"));
        await dai.transfer(mariaUser.address, parseUnits("1000"));
        await exaToken.transfer(auditor.address, parseUnits("50"));
      });

      it("THEN maria's EXA balance should be 0", async () => {
        let balanceUserPre = await exaToken
          .connect(mariaUser)
          .balanceOf(mariaUser.address);

        expect(balanceUserPre).to.equal(0);
      });
      it("THEN bob's EXA balance should be 0", async () => {
        let balanceUserPre = await exaToken
          .connect(bobUser)
          .balanceOf(bobUser.address);

        expect(balanceUserPre).to.equal(0);
      });
      describe("AND GIVEN maria deposits DAI to the smart pool AND claims all rewards", () => {
        beforeEach(async () => {
          await dai
            .connect(mariaUser)
            .approve(fixedLenderDAI.address, parseUnits("1000"));
          await fixedLenderDAI
            .connect(mariaUser)
            .depositToSmartPool(parseUnits("100"));
          await auditor.connect(mariaUser).claimExaAll(mariaUser.address); // + 0.5 EXA for Maria
        });

        it("THEN maria's EXA balance should be 0.5", async () => {
          let balanceUserPost = await exaToken
            .connect(mariaUser)
            .balanceOf(mariaUser.address);

          expect(balanceUserPost).to.equal(parseUnits("0.5"));
        });
        it("AND WHEN maria deposits more DAI, THEN event DistributedSPSupplierExa is emitted", async () => {
          await expect(
            fixedLenderDAI
              .connect(mariaUser)
              .depositToSmartPool(parseUnits("100"))
          ).to.emit(auditor, "DistributedSPSupplierExa");
        });
        describe("AND GIVEN maria transfers 1/4 of her smart pool deposit voucher to bob", () => {
          let exaBalanceMariaPost: BigNumber;
          beforeEach(async () => {
            await eDAI
              .connect(mariaUser)
              .transfer(bobUser.address, parseUnits("25")); // + 0.5 EXA for Maria
          });
          it("THEN maria's EXA rewards increases 0.375 every block", async () => {
            await ethers.provider.send("evm_mine", []); // + 0.375 EXA for Maria
            await ethers.provider.send("evm_mine", []); // + 0.375 EXA for Maria
            await ethers.provider.send("evm_mine", []); // + 0.375 EXA for Maria

            await auditor.connect(mariaUser).claimExaAll(mariaUser.address); // + 0.375 EXA for Maria
            exaBalanceMariaPost = await exaToken.balanceOf(mariaUser.address);

            expect(exaBalanceMariaPost).to.be.eq(parseUnits("2.5"));
          });
          it("THEN bob's EXA rewards increases 0.125 every block", async () => {
            await ethers.provider.send("evm_mine", []); // + 0.125 EXA for Bob
            await ethers.provider.send("evm_mine", []); // + 0.125 EXA for Bob
            await ethers.provider.send("evm_mine", []); // + 0.125 EXA for Bob

            await auditor.connect(bobUser).claimExaAll(bobUser.address); // + 0.125 EXA for Bob
            let balanceBobPost = await exaToken.balanceOf(bobUser.address);

            expect(balanceBobPost).to.be.eq(parseUnits("0.5"));
          });
          describe("AND GIVEN maria transfers the rest of the smart pool deposit voucher to bob", () => {
            beforeEach(async () => {
              await eDAI
                .connect(mariaUser)
                .transfer(bobUser.address, parseUnits("75")); // + 0.375 EXA for Maria & + 0.125 EXA for Bob
            });
            it("THEN maria's EXA rewards does not increase after some blocks", async () => {
              await ethers.provider.send("evm_mine", []); // + 0 EXA for Maria
              await ethers.provider.send("evm_mine", []); // + 0 EXA for Maria
              await ethers.provider.send("evm_mine", []); // + 0 EXA for Maria

              await auditor.connect(mariaUser).claimExaAll(mariaUser.address); // + 0 EXA for Maria
              let balanceMaria = await exaToken.balanceOf(mariaUser.address);

              expect(balanceMaria).to.be.eq(parseUnits("1.375"));
            });
            it("THEN bob's EXA rewards increases 0.5 every block", async () => {
              await ethers.provider.send("evm_mine", []); // + 0.5 EXA for Bob
              await ethers.provider.send("evm_mine", []); // + 0.5 EXA for Bob
              await ethers.provider.send("evm_mine", []); // + 0.5 EXA for Bob

              await auditor.connect(bobUser).claimExaAll(bobUser.address); // + 0.5 EXA for Bob
              let balanceBob = await exaToken.balanceOf(bobUser.address);

              expect(balanceBob).to.be.eq(parseUnits("2.125"));
            });
          });
        });
        describe("AND GIVEN maria withdraws DAI from the smart pool AND claims all rewards", () => {
          beforeEach(async () => {
            await fixedLenderDAI
              .connect(mariaUser)
              .withdrawFromSmartPool(parseUnits("100"));
            await auditor.connect(mariaUser).claimExaAll(mariaUser.address);
          });

          it("THEN maria's EXA balance should be 1", async () => {
            let balanceUserPost = await exaToken
              .connect(mariaUser)
              .balanceOf(mariaUser.address);

            expect(balanceUserPost).to.equal(parseUnits("1"));
          });
          it("AND WHEN maria claims rewards once again, she still has 1", async () => {
            await auditor.connect(mariaUser).claimExaAll(mariaUser.address);
            let balanceUserPost = await exaToken
              .connect(mariaUser)
              .balanceOf(mariaUser.address);

            expect(balanceUserPost).to.equal(parseUnits("1"));
          });
          it("AND WHEN maria withdraws more DAI from the smart pool, THEN event DistributedSPSupplierExa is emitted", async () => {
            await fixedLenderDAI
              .connect(mariaUser)
              .depositToSmartPool(parseUnits("100"));

            await expect(
              fixedLenderDAI
                .connect(mariaUser)
                .withdrawFromSmartPool(parseUnits("100"))
            ).to.emit(auditor, "DistributedSPSupplierExa");
          });
        });
      });
    });
  });

  describe("ExaLib", () => {
    let auditorHarness: Contract;
    let fixedLenderHarness: Contract;
    let exaToken: Contract;
    before(async () => {
      rewardsLibEnv = await RewardsLibEnv.create();
      auditorHarness = rewardsLibEnv.auditorHarness;
      fixedLenderHarness = rewardsLibEnv.fixedLenderHarness;
      exaToken = rewardsLibEnv.exaToken;
      [, mariaUser] = await ethers.getSigners();
    });
    describe("updateExaSPSupplyIndex", () => {
      describe("GIVEN a jump in blocks, AND an update in the Exa Smart Pool Supply Index", () => {
        let amountToDeposit = parseUnits("10");
        let blocksDelta = 100;
        beforeEach(async () => {
          // Call exaSpeed and jump blocksDelta
          await auditorHarness.setBlockNumber(0);
          await auditorHarness.setExaSpeed(
            fixedLenderHarness.address,
            parseUnits("0.5")
          );
          await auditorHarness.setBlockNumber(blocksDelta);
          await fixedLenderHarness.setTotalSPDeposits(
            mariaUser.address,
            amountToDeposit
          );
          await auditorHarness.updateExaSPSupplyIndex(
            fixedLenderHarness.address
          );
        });
        it("THEN it should calculate EXA smart pool supply index correctly", async () => {
          const [newIndex] = await auditorHarness.getSmartSupplyState(
            fixedLenderHarness.address
          );

          let exaAccruedDelta = parseUnits("0.5").mul(blocksDelta);
          let ratioDelta = exaAccruedDelta
            .mul(parseUnits("1", 36))
            .div(amountToDeposit);

          let newIndexCalculated = parseUnits("1", 36).add(ratioDelta);
          expect(newIndex).to.be.equal(newIndexCalculated);
        });
      });
      describe("GIVEN no blocks passed since last accrual, AND an update in the Exa Smart Pool Supply Index", () => {
        beforeEach(async () => {
          await auditorHarness.setBlockNumber(0);
          await auditorHarness.setExaSpeed(
            fixedLenderHarness.address,
            parseUnits("0.5")
          );
          await fixedLenderHarness.setTotalSPDeposits(
            mariaUser.address,
            parseUnits("10000")
          );
          await auditorHarness.updateExaSPSupplyIndex(
            fixedLenderHarness.address
          );
        });
        it("THEN it should not update smart pool supply index", async () => {
          const [newIndex, block] = await auditorHarness.getSmartSupplyState(
            fixedLenderHarness.address
          );
          expect(newIndex).to.equal(parseUnits("1", 36));
          expect(block).to.equal(0);
        });
      });
      describe("GIVEN an EXA speed of 0", () => {
        beforeEach(async () => {
          // Update borrows
          await auditorHarness.setBlockNumber(0);
          await auditorHarness.setExaSpeed(
            fixedLenderHarness.address,
            parseUnits("0.5")
          );
          await auditorHarness.setBlockNumber(100);
          await auditorHarness.setExaSpeed(fixedLenderHarness.address, 0);
          await fixedLenderHarness.setTotalSPDeposits(
            mariaUser.address,
            parseUnits("10000")
          );
          await auditorHarness.updateExaSPSupplyIndex(
            fixedLenderHarness.address
          );
        });
        it("THEN it should not update smart pool supply index", async () => {
          const [newIndex, block] = await auditorHarness.getSmartSupplyState(
            fixedLenderHarness.address
          );
          expect(newIndex).to.equal(parseUnits("1", 36));
          expect(block).to.equal(100);
        });
      });
    });
    describe("distributeSPSupplierExa", () => {
      describe("GIVEN a first time user deposit and distribution of rewards", () => {
        beforeEach(async () => {
          await exaToken.transfer(auditorHarness.address, parseUnits("50"));
          await fixedLenderHarness.setTotalSPDeposits(
            mariaUser.address,
            parseUnits("5")
          );
          await auditorHarness.setExaSPSupplyState(
            fixedLenderHarness.address,
            parseUnits("6", 36),
            10
          );
        });

        it("THEN it should transfer EXA and update smart pool supplier index correctly", async () => {
          let tx = await auditorHarness.distributeAllSPSupplierExa(
            fixedLenderHarness.address,
            mariaUser.address
          );
          let accrued = await auditorHarness.getExaAccrued(mariaUser.address);
          let balance = await exaToken.balanceOf(mariaUser.address);
          expect(accrued).to.equal(0);
          expect(balance).to.equal(parseUnits("25"));
          expect(tx)
            .to.emit(auditorHarness, "DistributedSPSupplierExa")
            .withArgs(
              fixedLenderHarness.address,
              mariaUser.address,
              parseUnits("25"),
              parseUnits("6", 36)
            );
        });
        describe("AND GIVEN a first time user deposit and distribution of rewards", () => {
          beforeEach(async () => {
            await auditorHarness.setExaSPSupplierIndex(
              fixedLenderHarness.address,
              mariaUser.address,
              parseUnits("2", 36)
            );
            await auditorHarness.distributeAllSPSupplierExa(
              fixedLenderHarness.address,
              mariaUser.address
            );
          });
          it("THEN it should update EXA accrued and smart pool supplier index for repeat user", async () => {
            /**
             * supplierAmount  = 5e18
             * deltaIndex      = marketStoredIndex - userStoredIndex
             *                 = 6e36 - 2e36 = 4e36
             * suppliedAccrued+= supplierTokens * deltaIndex / 1e36
             *                 = 5e18 * 4e36 / 1e36 = 20e18
             */

            let accrued = await auditorHarness.getExaAccrued(mariaUser.address);
            let balance = await exaToken.balanceOf(mariaUser.address);
            expect(accrued).to.equal(0);
            expect(balance).to.equal(parseUnits("20"));
          });
        });
      });
      describe("GIVEN a deposit without EXA distribution", () => {
        beforeEach(async () => {
          await exaToken.transfer(auditorHarness.address, parseUnits("50"));
          await fixedLenderHarness.setTotalSPDeposits(
            mariaUser.address,
            parseUnits("0.5")
          );
          await auditorHarness.setExaSPSupplyState(
            fixedLenderHarness.address,
            parseUnits("1.0019", 36),
            10
          );
        });
        it("THEN it should not transfer EXA automatically", async () => {
          /**
           * supplierAmount  = 5e17
           * deltaIndex      = marketStoredIndex - userStoredIndex
           *                 = 1.0019e36 - 1e36 = 0.0019e36
           * suppliedAccrued+= supplierTokens * deltaIndex / 1e36
           *                 = 5e17 * 0.0019e36 / 1e36 = 0.00095e18
           */
          await auditorHarness.distributeSPSupplierExa(
            fixedLenderHarness.address,
            mariaUser.address
          );
          let accrued = await auditorHarness.getExaAccrued(mariaUser.address);
          let balance = await exaToken.balanceOf(mariaUser.address);
          expect(accrued).to.equal(parseUnits("0.00095"));
          expect(balance).to.equal(0);
        });
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
