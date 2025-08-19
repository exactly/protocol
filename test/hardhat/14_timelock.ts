import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { Auditor, TimelockController } from "../../types";
import timelockExecute from "./utils/timelockExecute";

const { ZeroAddress, ZeroHash, getUnnamedSigners, getNamedSigner, getContract, keccak256, toUtf8Bytes, provider } =
  ethers;

describe("Timelock - AccessControl", function () {
  let auditor: Auditor;
  let timelockController: TimelockController;
  let owner: SignerWithAddress;
  let account: SignerWithAddress;
  let priceFeed: string;
  let marketDAI: string;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [account] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture("Markets");

    auditor = await getContract<Auditor>("Auditor", owner);
    timelockController = await getContract<TimelockController>("TimelockController", owner);
    priceFeed = (await deployments.get("PriceFeedDAI")).address;
    marketDAI = (await deployments.get("MarketDAI")).address;

    await timelockExecute(owner, auditor, "grantRole", [ZeroHash, owner.address]);
  });

  describe("GIVEN a deployed Auditor contract", () => {
    it("THEN it should not revert when setting a new asset source with owner address", async () => {
      await expect(auditor.setPriceFeed(marketDAI, priceFeed)).to.not.be.reverted;
    });

    describe("AND GIVEN a deployed Timelock contract", () => {
      it("THEN owner address doesn't have TIMELOCK_ADMIN role for Timelock contract", async () => {
        const TIMELOCK_ADMIN_ROLE = keccak256(toUtf8Bytes("TIMELOCK_ADMIN_ROLE"));
        expect(await timelockController.hasRole(TIMELOCK_ADMIN_ROLE, owner.address)).to.equal(false);
      });

      describe("AND WHEN the owner grants the ADMIN role to the Timelock contract address", () => {
        beforeEach(async () => {
          await auditor.grantRole(ZeroHash, timelockController.target);
        });

        it("THEN it should still not revert when setting new asset sources with owner address", async () => {
          await expect(auditor.setPriceFeed(marketDAI, priceFeed)).to.not.be.reverted;
        });

        describe("AND WHEN the owner schedules a new asset source with a 3 second delay in the Timelock", () => {
          let calldata: string;

          beforeEach(async () => {
            calldata = auditor.interface.encodeFunctionData("setPriceFeed", [marketDAI, priceFeed]);
            await timelockController.schedule(auditor.target, 0, calldata, ZeroHash, ZeroHash, 3);
          });

          it("THEN it should revert when executing before delay time", async () => {
            await expect(
              timelockController.execute(auditor.target, 0, calldata, ZeroHash, ZeroHash),
            ).to.be.revertedWithoutReason();
          });

          it("THEN it should not revert when executing after delay time", async () => {
            await provider.send("evm_mine", []);
            await provider.send("evm_mine", []);
            await expect(timelockController.execute(auditor.target, 0, calldata, ZeroHash, ZeroHash)).to.not.be
              .reverted;
          });
        });

        it("AND WHEN account tries to schedule a set of new asset sources through the Timelock, THEN it should revert", async () => {
          const data = auditor.interface.encodeFunctionData("setPriceFeed", [ZeroAddress, ZeroAddress]);
          await expect(
            timelockController.connect(account).schedule(auditor.target, 0, data, ZeroHash, ZeroHash, 3),
          ).to.be.revertedWithoutReason();
        });

        describe("AND WHEN the owner revokes his ADMIN role", () => {
          beforeEach(async () => {
            await auditor.revokeRole(ZeroHash, owner.address);
          });

          it("THEN it should revert when trying to set new asset sources with owner address", async () => {
            await expect(auditor.setPriceFeed(marketDAI, priceFeed)).to.be.revertedWithoutReason();
          });
        });

        describe("AND WHEN the owner address grants another account PROPOSER and EXECUTOR roles for Timelock contract", () => {
          let PROPOSER_ROLE: string;
          let EXECUTOR_ROLE: string;

          beforeEach(async () => {
            PROPOSER_ROLE = keccak256(toUtf8Bytes("PROPOSER_ROLE"));
            EXECUTOR_ROLE = keccak256(toUtf8Bytes("EXECUTOR_ROLE"));
            await timelockExecute(owner, timelockController, "grantRole", [PROPOSER_ROLE, account.address]);
            await timelockExecute(owner, timelockController, "grantRole", [EXECUTOR_ROLE, account.address]);
          });

          it("THEN account has roles", async () => {
            const userHasProposerRole = await timelockController.hasRole(PROPOSER_ROLE, account.address);
            const userHasExecutorRole = await timelockController.hasRole(EXECUTOR_ROLE, account.address);
            expect(userHasExecutorRole).to.equal(true);
            expect(userHasProposerRole).to.equal(true);
          });

          it("THEN account can schedule and execute transactions through the Timelock", async () => {
            const data = auditor.interface.encodeFunctionData("setPriceFeed", [ZeroAddress, priceFeed]);
            await expect(timelockController.connect(account).schedule(auditor.target, 0, data, ZeroHash, ZeroHash, 1))
              .to.not.be.reverted;
            await expect(timelockController.connect(account).execute(auditor.target, 0, data, ZeroHash, ZeroHash)).to
              .not.be.reverted;
          });

          it("THEN it should revert when account tries to grant another address PROPOSER and EXECUTOR roles for Timelock contract", async () => {
            // Only addresses with TIMELOCK_ADMIN_ROLE can grant these roles
            await expect(
              timelockController.connect(account).grantRole(PROPOSER_ROLE, ZeroAddress),
            ).to.be.revertedWithoutReason();
            await expect(
              timelockController.connect(account).grantRole(EXECUTOR_ROLE, ZeroAddress),
            ).to.be.revertedWithoutReason();
          });
        });
      });
    });
  });
});
