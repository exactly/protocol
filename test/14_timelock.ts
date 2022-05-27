import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Timelock - AccessControl", function () {
  let exactlyOracle: Contract;
  let timelockController: Contract;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  const { AddressZero, HashZero } = ethers.constants;

  const assetSymbol = "LINK";
  const assetAddress = "0x514910771AF9Ca656af840dff83E8264EcF986CA";

  describe("GIVEN a deployed ExactlyOracle contract", () => {
    beforeEach(async () => {
      [owner, user] = await ethers.getSigners();

      const ExactlyOracle = await ethers.getContractFactory("ExactlyOracle");
      exactlyOracle = await ExactlyOracle.deploy(AddressZero, [], [], AddressZero, 0);
      await exactlyOracle.deployed();
    });
    it("THEN it should not revert when setting new asset sources with owner address", async () => {
      await expect(exactlyOracle.setAssetSources([assetSymbol], [assetAddress])).to.not.be.reverted;
    });
    describe("AND GIVEN a deployed Timelock contract", () => {
      beforeEach(async () => {
        const TimelockController = await ethers.getContractFactory("TimelockController");
        timelockController = await TimelockController.deploy(1, [owner.address], [owner.address]);
        await timelockController.deployed();
      });
      it("THEN owner address has TIMELOCK_ADMIN role for Timelock contract", async () => {
        const TIMELOCK_ADMIN_ROLE = await timelockController.TIMELOCK_ADMIN_ROLE();
        const ownerHasTimelockAdminRole = await timelockController.hasRole(TIMELOCK_ADMIN_ROLE, owner.address);
        expect(ownerHasTimelockAdminRole).to.equal(true);
      });
      describe("AND WHEN the owner grants the ADMIN role to the Timelock contract address", () => {
        let ADMIN_ROLE: any;
        beforeEach(async () => {
          ADMIN_ROLE = await exactlyOracle.DEFAULT_ADMIN_ROLE();
          await exactlyOracle.grantRole(ADMIN_ROLE, timelockController.address);
        });
        it("THEN it should still not revert when setting new asset sources with owner address", async () => {
          await expect(exactlyOracle.setAssetSources([assetSymbol], [assetAddress])).to.not.be.reverted;
        });
        describe("AND WHEN the owner schedules a new asset source with a 3 second delay in the Timelock", () => {
          let txData: any;
          beforeEach(async () => {
            let tx = await exactlyOracle.setAssetSources([assetSymbol], [assetAddress]);
            txData = tx.data;

            await timelockController.schedule(exactlyOracle.address, 0, txData, HashZero, HashZero, 3);
          });
          it("THEN it should revert when executing before delay time", async () => {
            await expect(
              timelockController.execute(exactlyOracle.address, 0, txData, HashZero, HashZero),
            ).to.be.revertedWith("TimelockController: operation is not ready");
          });
          it("THEN it should not revert when executing after delay time", async () => {
            await ethers.provider.send("evm_mine", []);
            await ethers.provider.send("evm_mine", []);

            await expect(timelockController.execute(exactlyOracle.address, 0, txData, HashZero, HashZero)).to.not.be
              .reverted;
          });
        });
        it("AND WHEN user tries to schedule a set of new asset sources through the Timelock, THEN it should revert", async () => {
          let tx = await exactlyOracle.setAssetSources([assetSymbol], [AddressZero]);
          const txData = tx.data;

          await expect(
            timelockController.connect(user).schedule(exactlyOracle.address, 0, txData, HashZero, HashZero, 3),
          ).to.be.revertedWith("AccessControl");
        });
        describe("AND WHEN the owner revokes his ADMIN role", () => {
          beforeEach(async () => {
            await exactlyOracle.revokeRole(ADMIN_ROLE, owner.address);
          });
          it("THEN it should revert when trying to set new asset sources with owner address", async () => {
            await expect(exactlyOracle.setAssetSources([assetSymbol], [assetAddress])).to.be.revertedWith(
              "AccessControl",
            );
          });
        });
        describe("AND WHEN the owner address grants another user PROPOSER and EXECUTOR roles for Timelock contract", () => {
          let PROPOSER_ROLE: any;
          let EXECUTOR_ROLE: any;
          beforeEach(async () => {
            PROPOSER_ROLE = await timelockController.PROPOSER_ROLE();
            EXECUTOR_ROLE = await timelockController.EXECUTOR_ROLE();
            await timelockController.grantRole(PROPOSER_ROLE, user.address);
            await timelockController.grantRole(EXECUTOR_ROLE, user.address);
          });
          it("THEN user has roles", async () => {
            const userHasProposerRole = await timelockController.hasRole(PROPOSER_ROLE, user.address);
            const userHasExecutorRole = await timelockController.hasRole(EXECUTOR_ROLE, user.address);
            expect(userHasExecutorRole).to.equal(true);
            expect(userHasProposerRole).to.equal(true);
          });
          it("THEN user can schedule and execute transactions through the Timelock", async () => {
            let tx = await exactlyOracle.setAssetSources([assetSymbol], [AddressZero]);
            const txData = tx.data;

            await expect(
              timelockController.connect(user).schedule(exactlyOracle.address, 0, txData, HashZero, HashZero, 1),
            ).to.not.be.reverted;
            await expect(timelockController.connect(user).execute(exactlyOracle.address, 0, txData, HashZero, HashZero))
              .to.not.be.reverted;
          });
          it("THEN it should revert when user tries to grant another address PROPOSER and EXECUTOR roles for Timelock contract", async () => {
            // Only addresses with TIMELOCK_ADMIN_ROLE can grant these roles
            await expect(timelockController.connect(user).grantRole(PROPOSER_ROLE, AddressZero)).to.be.revertedWith(
              "AccessControl",
            );
            await expect(timelockController.connect(user).grantRole(EXECUTOR_ROLE, AddressZero)).to.be.revertedWith(
              "AccessControl",
            );
          });
        });
      });
    });
  });
});
