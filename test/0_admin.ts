import { expect } from "chai";
import { ethers, deployments, network } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { Auditor, Market, MockERC20 } from "../types";
import timelockExecute from "./utils/timelockExecute";

const {
  constants: { AddressZero },
  utils: { parseUnits },
  getUnnamedSigners,
  getNamedSigner,
  getContract,
} = ethers;

const { deploy, fixture, get } = deployments;

describe("Auditor Admin", function () {
  let dai: MockERC20;
  let auditor: Auditor;
  let marketDAI: Market;
  let laura: SignerWithAddress;
  let owner: SignerWithAddress;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [laura] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await fixture(["Markets"]);

    dai = await getContract<MockERC20>("DAI", laura);
    auditor = await getContract<Auditor>("Auditor", laura);
    marketDAI = await getContract<Market>("MarketDAI", laura);

    await dai.connect(owner).mint(laura.address, "10000");
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
  });

  describe("GIVEN the ADMIN/owner user", () => {
    beforeEach(async () => {
      const ADMIN_ROLE = await auditor.DEFAULT_ADMIN_ROLE();
      expect(await auditor.hasRole(ADMIN_ROLE, owner.address)).to.equal(false);
      expect(await marketDAI.hasRole(ADMIN_ROLE, owner.address)).to.equal(false);

      await timelockExecute(owner, auditor, "grantRole", [ADMIN_ROLE, owner.address]);

      auditor = auditor.connect(owner);
    });

    it("WHEN trying to enable a market for the second time, THEN the transaction should revert with MARKET_ALREADY_LISTED", async () => {
      await expect(auditor.enableMarket(marketDAI.address, 0, await dai.decimals())).to.be.revertedWith(
        "MarketAlreadyListed()",
      );
    });

    it("WHEN trying to set a new market with a different auditor, THEN the transaction should revert with AUDITOR_MISMATCH", async () => {
      const newAuditor = await deploy("NewAuditor", {
        contract: "Auditor",
        args: [laura.address, { liquidator: parseUnits("0.05"), lenders: parseUnits("0.01") }],
        from: owner.address,
      });
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
        from: owner.address,
      });
      await expect(auditor.enableMarket(market.address, parseUnits("0.5"), await dai.decimals())).to.be.revertedWith(
        "AuditorMismatch()",
      );
    });

    it("WHEN trying to retrieve all markets, THEN the addresses should match the ones passed on deploy", async () => {
      expect(await auditor.allMarkets()).to.deep.equal(
        await Promise.all(network.config.tokens.map(async (token) => (await get(`Market${token}`)).address)),
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
        from: owner.address,
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
  });
});
