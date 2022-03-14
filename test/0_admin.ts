import { expect } from "chai";
import { ethers, deployments, network } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { Auditor, FixedLender, MockedToken, PoolAccounting } from "../types";
import GenericError, { ErrorCode } from "./utils/GenericError";
import timelockExecute from "./utils/timelockExecute";

const {
  utils: { parseUnits },
  getUnnamedSigners,
  getNamedSigner,
  getContract,
} = ethers;

const { deploy, fixture, get } = deployments;

describe("Auditor Admin", function () {
  let dai: MockedToken;
  let auditor: Auditor;
  let fixedLenderDAI: FixedLender;
  let poolAccountingDAI: PoolAccounting;
  let laura: SignerWithAddress;
  let owner: SignerWithAddress;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [laura] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await fixture(["Markets"]);

    dai = await getContract<MockedToken>("DAI", laura);
    auditor = await getContract<Auditor>("Auditor", laura);
    fixedLenderDAI = await getContract<FixedLender>("FixedLenderDAI", laura);
    poolAccountingDAI = await getContract<PoolAccounting>("PoolAccountingDAI", laura);

    await dai.connect(owner).transfer(laura.address, "10000");
  });

  describe("GIVEN a regular user", () => {
    it("WHEN trying to enable a market, THEN the transaction should revert with Access Control", async () => {
      await expect(
        auditor.enableMarket(fixedLenderDAI.address, 0, "DAI", "DAI", await dai.decimals()),
      ).to.be.revertedWith("AccessControl");
    });

    it("WHEN trying to set liquidation incentive, THEN the transaction should revert with Access Control", async () => {
      await expect(auditor.setLiquidationIncentive(parseUnits("1.01"))).to.be.revertedWith("AccessControl");
    });

    it("WHEN trying to set a new oracle, THEN the transaction should revert with Access Control", async () => {
      await expect(auditor.setOracle((await get("ExactlyOracle")).address)).to.be.revertedWith("AccessControl");
    });

    it("WHEN trying to set collateral factor, THEN the transaction should revert with Access Control", async () => {
      await expect(auditor.setCollateralFactor(fixedLenderDAI.address, 1)).to.be.revertedWith("AccessControl");
    });

    it("WHEN trying to set borrow caps, THEN the transaction should revert with Access Control", async () => {
      await expect(auditor.setMarketBorrowCaps([fixedLenderDAI.address], ["1000000"])).to.be.revertedWith(
        "AccessControl",
      );
    });
  });

  describe("GIVEN the ADMIN/owner user", () => {
    beforeEach(async () => {
      const ADMIN_ROLE = await auditor.DEFAULT_ADMIN_ROLE();
      expect(await auditor.hasRole(ADMIN_ROLE, owner.address)).to.equal(false);
      expect(await fixedLenderDAI.hasRole(ADMIN_ROLE, owner.address)).to.equal(false);
      expect(await poolAccountingDAI.hasRole(ADMIN_ROLE, owner.address)).to.equal(false);

      await timelockExecute(owner, auditor, "grantRole", [ADMIN_ROLE, owner.address]);
      await timelockExecute(owner, poolAccountingDAI, "grantRole", [ADMIN_ROLE, owner.address]);

      auditor = auditor.connect(owner);
      poolAccountingDAI = poolAccountingDAI.connect(owner);
    });

    it("WHEN trying to enable a market for the second time, THEN the transaction should revert with MARKET_ALREADY_LISTED", async () => {
      await expect(
        auditor.enableMarket(fixedLenderDAI.address, 0, "DAI", "DAI", await dai.decimals()),
      ).to.be.revertedWith("MarketAlreadyListed()");
    });

    it("WHEN trying to set a new fixedLender with a different auditor, THEN the transaction should revert with AUDITOR_MISMATCH", async () => {
      const newAuditor = await deploy("NewAuditor", {
        contract: "Auditor",
        libraries: { MarketsLib: (await get("MarketsLib")).address },
        args: [laura.address],
        from: owner.address,
      });
      const fixedLender = await deploy("NewFixedLender", {
        contract: "FixedLender",
        args: [dai.address, "DAI", (await get("ETokenDAI")).address, newAuditor.address, poolAccountingDAI.address],
        from: owner.address,
      });
      await expect(
        auditor.enableMarket(fixedLender.address, 0, "Parallel DAI", "Parallel DAI", await dai.decimals()),
      ).to.be.revertedWith("AuditorMismatch()");
    });

    it("WHEN trying to set borrow caps on an unlisted market, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(auditor.setMarketBorrowCaps([laura.address], [parseUnits("1000")])).to.be.revertedWith(
        "MarketNotListed()",
      );
    });

    it("WHEN trying to set borrow caps with arguments mismatch, THEN the transaction should revert with INVALID_SET_BORROW_CAP", async () => {
      await expect(auditor.setMarketBorrowCaps([fixedLenderDAI.address], [])).to.be.revertedWith("InvalidBorrowCaps()");
    });

    it("WHEN trying to retrieve all markets, THEN the addresses should match the ones passed on deploy", async () => {
      expect(await auditor.getMarketAddresses()).to.deep.equal(
        await Promise.all(network.config.tokens.map(async (token) => (await get(`FixedLender${token}`)).address)),
      );
    });

    it("WHEN trying to set a new market, THEN the auditor should emit MarketListed event", async () => {
      const fixedLender = await deploy("NewFixedLender", {
        contract: "FixedLender",
        args: [dai.address, "DAI", (await get("ETokenDAI")).address, auditor.address, poolAccountingDAI.address],
        from: owner.address,
      });
      await expect(auditor.enableMarket(fixedLender.address, parseUnits("0.5"), "DAI", "DAI", 18))
        .to.emit(auditor, "MarketListed")
        .withArgs(fixedLender.address);
    });

    it("WHEN setting new oracle, THEN the auditor should emit OracleChanged event", async () => {
      await expect(auditor.setOracle((await get("ExactlyOracle")).address)).to.emit(auditor, "OracleChanged");
    });

    it("WHEN setting collateral factor, THEN the auditor should emit NewCollateralFactor event", async () => {
      await expect(auditor.setCollateralFactor(fixedLenderDAI.address, 1))
        .to.emit(auditor, "NewCollateralFactor")
        .withArgs(fixedLenderDAI.address, 1);
      expect((await auditor.getMarketData(fixedLenderDAI.address))[3]).to.equal(1);
    });

    it("WHEN setting max borrow caps, THEN the auditor should emit NewBorrowCap event", async () => {
      await expect(auditor.setMarketBorrowCaps([fixedLenderDAI.address], ["10000"])).to.emit(auditor, "NewBorrowCap");
    });

    it("WHEN initializing a poolAccounting contract, THEN it should revert with CONTRACT_ALREADY_INITIALIZED", async () => {
      await expect(poolAccountingDAI.initialize(owner.address)).to.be.revertedWith(
        GenericError(ErrorCode.CONTRACT_ALREADY_INITIALIZED),
      );
    });
  });
});
