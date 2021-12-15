import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Timelock - AccessControl", function () {
  let exactlyOracle: Contract;
  let timelockController: Contract;
  let owner: SignerWithAddress;

  const { AddressZero, HashZero } = ethers.constants;

  const assetSymbol = "LINK";
  const assetAddress = "0x514910771AF9Ca656af840dff83E8264EcF986CA";

  describe("GIVEN a deployed ExactlyOracle contract", () => {
    beforeEach(async () => {
      [owner] = await ethers.getSigners();

      const ExactlyOracle = await ethers.getContractFactory("ExactlyOracle");
      exactlyOracle = await ExactlyOracle.deploy(
        AddressZero,
        [],
        [],
        AddressZero
      );
      await exactlyOracle.deployed();
    });
    it("THEN it should not revert when setting new asset sources with owner address", async () => {
      await expect(exactlyOracle.setAssetSources([assetSymbol], [assetAddress]))
        .to.not.be.reverted;
    });
    describe("AND GIVEN a deployed Timelock contract", () => {
      beforeEach(async () => {
        const TimelockController = await ethers.getContractFactory(
          "TimelockController"
        );
        timelockController = await TimelockController.deploy(
          1,
          [owner.address],
          [owner.address]
        );
        await timelockController.deployed();
      });
      describe("AND GIVEN a grant in the ADMIN role to the Timelock contract address", () => {
        let ADMIN_ROLE: any;
        beforeEach(async () => {
          ADMIN_ROLE = await exactlyOracle.DEFAULT_ADMIN_ROLE();
          await exactlyOracle.grantRole(ADMIN_ROLE, timelockController.address);
        });
        it("THEN it should still not revert when setting new asset sources with owner address", async () => {
          await expect(
            exactlyOracle.setAssetSources([assetSymbol], [assetAddress])
          ).to.not.be.reverted;
        });
        describe("AND GIVEN a schedule with 3 seconds delay to set new asset sources through the Timelock", () => {
          let txData: any;
          beforeEach(async () => {
            let tx = await exactlyOracle.setAssetSources(
              [assetSymbol],
              [assetAddress]
            );
            txData = tx.data;

            await timelockController.schedule(
              exactlyOracle.address,
              0,
              txData,
              HashZero,
              HashZero,
              3
            );
          });
          it("THEN it should revert when executing before delay time", async () => {
            await expect(
              timelockController.execute(
                exactlyOracle.address,
                0,
                txData,
                HashZero,
                HashZero
              )
            ).to.be.revertedWith("TimelockController: operation is not ready");
          });
          it("THEN it should not revert when executing after delay time", async () => {
            await ethers.provider.send("evm_mine", []);
            await ethers.provider.send("evm_mine", []);

            await expect(
              timelockController.execute(
                exactlyOracle.address,
                0,
                txData,
                HashZero,
                HashZero
              )
            ).to.not.be.reverted;
          });
          describe("AND GIVEN a revoke in the ADMIN role of the owner's address", () => {
            beforeEach(async () => {
              await exactlyOracle.revokeRole(ADMIN_ROLE, owner.address);
            });
            it("THEN it should revert when trying to set new asset sources with owner address", async () => {
              await expect(
                exactlyOracle.setAssetSources([assetSymbol], [assetAddress])
              ).to.be.reverted;
            });
          });
        });
      });
    });
  });
});
