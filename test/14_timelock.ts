import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { ExactlyOracle, TimelockController } from "../types";
import timelockExecute from "./utils/timelockExecute";

const {
  constants: { AddressZero, HashZero },
  getUnnamedSigners,
  getNamedSigner,
  getContract,
  provider,
} = ethers;

describe("Timelock - AccessControl", function () {
  let exactlyOracle: ExactlyOracle;
  let timelockController: TimelockController;
  let owner: SignerWithAddress;
  let account: SignerWithAddress;
  let priceFeed: string;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [account] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture("Markets");

    exactlyOracle = await getContract<ExactlyOracle>("ExactlyOracle", owner);
    timelockController = await getContract<TimelockController>("TimelockController", owner);
    priceFeed = (await deployments.get("PriceFeedDAI")).address;

    await timelockExecute(owner, exactlyOracle, "grantRole", [await exactlyOracle.DEFAULT_ADMIN_ROLE(), owner.address]);
  });

  describe("GIVEN a deployed ExactlyOracle contract", () => {
    it("THEN it should not revert when setting a new asset source with owner address", async () => {
      await expect(exactlyOracle.setPriceFeed(AddressZero, priceFeed)).to.not.be.reverted;
    });
    describe("AND GIVEN a deployed Timelock contract", () => {
      it("THEN owner address doesn't have TIMELOCK_ADMIN role for Timelock contract", async () => {
        const TIMELOCK_ADMIN_ROLE = await timelockController.TIMELOCK_ADMIN_ROLE();
        expect(await timelockController.hasRole(TIMELOCK_ADMIN_ROLE, owner.address)).to.equal(false);
      });
      describe("AND WHEN the owner grants the ADMIN role to the Timelock contract address", () => {
        beforeEach(async () => {
          await exactlyOracle.grantRole(await exactlyOracle.DEFAULT_ADMIN_ROLE(), timelockController.address);
        });
        it("THEN it should still not revert when setting new asset sources with owner address", async () => {
          await expect(exactlyOracle.setPriceFeed(AddressZero, priceFeed)).to.not.be.reverted;
        });
        describe("AND WHEN the owner schedules a new asset source with a 3 second delay in the Timelock", () => {
          let calldata: string;
          beforeEach(async () => {
            calldata = exactlyOracle.interface.encodeFunctionData("setPriceFeed", [AddressZero, priceFeed]);
            await timelockController.schedule(exactlyOracle.address, 0, calldata, HashZero, HashZero, 3);
          });
          it("THEN it should revert when executing before delay time", async () => {
            await expect(
              timelockController.execute(exactlyOracle.address, 0, calldata, HashZero, HashZero),
            ).to.be.revertedWith("TimelockController: operation is not ready");
          });
          it("THEN it should not revert when executing after delay time", async () => {
            await provider.send("evm_mine", []);
            await provider.send("evm_mine", []);
            await expect(timelockController.execute(exactlyOracle.address, 0, calldata, HashZero, HashZero)).to.not.be
              .reverted;
          });
        });
        it("AND WHEN account tries to schedule a set of new asset sources through the Timelock, THEN it should revert", async () => {
          const data = exactlyOracle.interface.encodeFunctionData("setPriceFeed", [AddressZero, AddressZero]);
          await expect(
            timelockController.connect(account).schedule(exactlyOracle.address, 0, data, HashZero, HashZero, 3),
          ).to.be.revertedWith("AccessControl");
        });
        describe("AND WHEN the owner revokes his ADMIN role", () => {
          beforeEach(async () => {
            await exactlyOracle.revokeRole(await exactlyOracle.DEFAULT_ADMIN_ROLE(), owner.address);
          });
          it("THEN it should revert when trying to set new asset sources with owner address", async () => {
            await expect(exactlyOracle.setPriceFeed(AddressZero, priceFeed)).to.be.revertedWith("AccessControl");
          });
        });
        describe("AND WHEN the owner address grants another account PROPOSER and EXECUTOR roles for Timelock contract", () => {
          let PROPOSER_ROLE: string;
          let EXECUTOR_ROLE: string;
          beforeEach(async () => {
            PROPOSER_ROLE = await timelockController.PROPOSER_ROLE();
            EXECUTOR_ROLE = await timelockController.EXECUTOR_ROLE();
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
            const data = exactlyOracle.interface.encodeFunctionData("setPriceFeed", [AddressZero, priceFeed]);
            await expect(
              timelockController.connect(account).schedule(exactlyOracle.address, 0, data, HashZero, HashZero, 1),
            ).to.not.be.reverted;
            await expect(
              timelockController.connect(account).execute(exactlyOracle.address, 0, data, HashZero, HashZero),
            ).to.not.be.reverted;
          });
          it("THEN it should revert when account tries to grant another address PROPOSER and EXECUTOR roles for Timelock contract", async () => {
            // Only addresses with TIMELOCK_ADMIN_ROLE can grant these roles
            await expect(timelockController.connect(account).grantRole(PROPOSER_ROLE, AddressZero)).to.be.revertedWith(
              "AccessControl",
            );
            await expect(timelockController.connect(account).grantRole(EXECUTOR_ROLE, AddressZero)).to.be.revertedWith(
              "AccessControl",
            );
          });
        });
      });
    });
  });
});
