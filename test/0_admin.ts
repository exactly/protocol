import { expect } from "chai";
import { ethers, deployments, config } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { Auditor, Market, MockERC20 } from "../types";
import timelockExecute from "./utils/timelockExecute";

const {
  constants: { AddressZero },
  utils: { parseUnits },
  getNamedSigner,
  getContract,
} = ethers;

const { deploy, fixture, get } = deployments;

describe("Auditor Admin", function () {
  let dai: MockERC20;
  let auditor: Auditor;
  let marketDAI: Market;
  let deployer: SignerWithAddress;
  let multisig: SignerWithAddress;

  before(async () => {
    deployer = await getNamedSigner("deployer");
    multisig = await getNamedSigner("multisig");
  });

  beforeEach(async () => {
    await fixture("Markets");

    dai = await getContract<MockERC20>("DAI", deployer);
    auditor = await getContract<Auditor>("Auditor", deployer);
    marketDAI = await getContract<Market>("MarketDAI", deployer);

    await dai.connect(multisig).mint(deployer.address, "10000");
  });

  describe("GIVEN a regular user", () => {
    it("WHEN trying to enable a market, THEN the transaction should revert with Access Control", async () => {
      await expect(auditor.enableMarket(marketDAI.address, 0, await dai.decimals())).to.be.revertedWith(
        "AccessControl",
      );
    });

    it("WHEN trying to set liquidation incentive, THEN the transaction should revert with Access Control", async () => {
      await expect(
        auditor.setLiquidationIncentive({ liquidator: parseUnits("0.05"), lenders: parseUnits("0.01") }),
      ).to.be.revertedWith("AccessControl");
    });

    it("WHEN trying to set a new oracle, THEN the transaction should revert with Access Control", async () => {
      await expect(auditor.setOracle((await get("ExactlyOracle")).address)).to.be.revertedWith("AccessControl");
    });

    it("WHEN trying to set adjust factor, THEN the transaction should revert with Access Control", async () => {
      await expect(auditor.setAdjustFactor(marketDAI.address, 1)).to.be.revertedWith("AccessControl");
    });

    it("WHEN trying to upgrade implementation, THEN the transaction should revert with NotAdmin", async () => {
      await expect(
        auditor.upgradeTo((await deploy("NewAuditor", { contract: "Auditor", from: deployer.address })).address),
      ).to.be.revertedWith("NotAdmin");
    });
  });

  describe("GIVEN the ADMIN/multisig user", () => {
    beforeEach(async () => {
      const ADMIN_ROLE = await auditor.DEFAULT_ADMIN_ROLE();
      expect(await auditor.hasRole(ADMIN_ROLE, multisig.address)).to.equal(false);
      expect(await marketDAI.hasRole(ADMIN_ROLE, multisig.address)).to.equal(false);

      await timelockExecute(multisig, auditor, "grantRole", [ADMIN_ROLE, multisig.address]);

      auditor = auditor.connect(multisig);
    });

    it("WHEN trying to enable a market for the second time, THEN the transaction should revert with MARKET_ALREADY_LISTED", async () => {
      await expect(auditor.enableMarket(marketDAI.address, 0, await dai.decimals())).to.be.revertedWith(
        "MarketAlreadyListed()",
      );
    });

    it("WHEN trying to set a new market with a different auditor, THEN the transaction should revert with AUDITOR_MISMATCH", async () => {
      const newAuditor = await deploy("NewAuditor", { contract: "Auditor", from: deployer.address });
      const market = await deploy("NewMarket", {
        contract: "Market",
        args: [
          dai.address,
          12,
          2,
          newAuditor.address,
          AddressZero,
          parseUnits("4", 11),
          parseUnits("0.2"),
          parseUnits("0.1"),
          { up: parseUnits("1"), down: parseUnits("1") },
        ],
        from: deployer.address,
      });
      await expect(auditor.enableMarket(market.address, parseUnits("0.5"), await dai.decimals())).to.be.revertedWith(
        "AuditorMismatch()",
      );
    });

    it("WHEN trying to retrieve all markets, THEN the addresses should match the ones passed on deploy", async () => {
      expect(await auditor.allMarkets()).to.deep.equal(
        await Promise.all(config.finance.assets.map(async (symbol) => (await get(`Market${symbol}`)).address)),
      );
    });

    it("WHEN trying to set a new market, THEN the auditor should emit MarketListed event", async () => {
      const market = await deploy("NewMarket", {
        contract: "Market",
        args: [
          dai.address,
          12,
          2,
          auditor.address,
          AddressZero,
          parseUnits("4", 11),
          parseUnits("0.2"),
          parseUnits("0.1"),
          { up: parseUnits("1"), down: parseUnits("1") },
        ],
        from: deployer.address,
      });
      await expect(auditor.enableMarket(market.address, parseUnits("0.5"), 18))
        .to.emit(auditor, "MarketListed")
        .withArgs(market.address, 18);
    });

    it("WHEN setting new oracle, THEN the auditor should emit OracleSet event", async () => {
      await expect(auditor.setOracle((await get("ExactlyOracle")).address)).to.emit(auditor, "OracleSet");
    });

    it("WHEN setting a new liquidation incentive, THEN the auditor should emit LiquidationIncentiveSet event", async () => {
      const incentive = { liquidator: parseUnits("0.05"), lenders: parseUnits("0.01") };
      await expect(auditor.setLiquidationIncentive(incentive)).to.emit(auditor, "LiquidationIncentiveSet");
      expect(await auditor.liquidationIncentive()).to.deep.eq([incentive.liquidator, incentive.lenders]);
    });

    it("WHEN setting adjust factor, THEN the auditor should emit AdjustFactorSet event", async () => {
      await expect(auditor.setAdjustFactor(marketDAI.address, parseUnits("0.7")))
        .to.emit(auditor, "AdjustFactorSet")
        .withArgs(marketDAI.address, parseUnits("0.7"));
      expect((await auditor.markets(marketDAI.address)).adjustFactor).to.equal(parseUnits("0.7"));
    });

    it("WHEN trying to upgrade implementation, THEN the transaction should revert with Access Control", async () => {
      await expect(
        auditor.upgradeTo((await deploy("NewAuditor", { contract: "Auditor", from: deployer.address })).address),
      ).to.be.revertedWith("NotAdmin");
    });
  });

  describe("Upgradeable", () => {
    let newAuditor: Auditor;

    beforeEach(async () => {
      await deploy("NewAuditor", { contract: "Auditor", from: deployer.address });
      newAuditor = await getContract<Auditor>("NewAuditor", deployer);
    });

    it("WHEN trying to initialize implementation, THEN the transaction should revert with NotAdmin", async () => {
      await expect(
        newAuditor.initialize(multisig.address, AddressZero, { liquidator: 0, lenders: 0 }),
      ).to.be.revertedWith("Initializable: contract is already initialized");
    });

    it("WHEN trying to upgrade implementation, THEN the auditor should emit Upgraded event", async () => {
      await expect(timelockExecute(multisig, auditor, "upgradeTo", [newAuditor.address]))
        .to.emit(auditor, "Upgraded")
        .withArgs(newAuditor.address);
    });
  });
});
