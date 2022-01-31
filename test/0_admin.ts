import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { ProtocolError, errorGeneric } from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv } from "./defaultEnv";

describe("Auditor Admin", function () {
  let auditor: Contract;
  let exactlyEnv: DefaultEnv;
  let laura: SignerWithAddress;
  let owner: SignerWithAddress;

  let mockedTokens = new Map([
    [
      "DAI",
      {
        decimals: 18,
        collateralRate: parseUnits("0.8"),
        usdPrice: parseUnits("1"),
      },
    ],
    [
      "WETH",
      {
        decimals: 18,
        collateralRate: parseUnits("0.7"),
        usdPrice: parseUnits("3000"),
      },
    ],
  ]);
  let snapshot: any;
  before(async () => {
    [owner, laura] = await ethers.getSigners();

    exactlyEnv = await DefaultEnv.create({ mockedTokens });
    auditor = exactlyEnv.auditor;

    await exactlyEnv.transfer("DAI", laura, "10000");

    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  describe("GIVEN a regular user", () => {
    beforeEach(async () => {
      exactlyEnv.switchWallet(laura);
    });

    it("WHEN trying to enable a market, THEN the transaction should revert with Access Control", async () => {
      let tx = exactlyEnv.enableMarket(
        exactlyEnv.getFixedLender("DAI").address,
        parseUnits("0"),
        "DAI",
        "DAI",
        mockedTokens.get("DAI")!.decimals
      );

      await expect(tx).to.be.revertedWith("AccessControl");
    });

    it("WHEN trying to set liquidation incentive, THEN the transaction should revert with Access Control", async () => {
      let tx = exactlyEnv.setLiquidationIncentive("1.01");
      await expect(tx).to.be.revertedWith("AccessControl");
    });

    it("WHEN trying to set a new oracle, THEN the transaction should revert with Access Control", async () => {
      let tx = exactlyEnv.setOracle(exactlyEnv.oracle.address);
      await expect(tx).to.be.revertedWith("AccessControl");
    });

    it("WHEN trying to set borrow caps, THEN the transaction should revert with Access Control", async () => {
      let tx = exactlyEnv.setBorrowCaps(["DAI"], ["1000000"]);
      await expect(tx).to.be.revertedWith("AccessControl");
    });

    describe("WHEN trying to set exa speed", async () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.setExaSpeed("DAI", "3000");
      });

      it("THEN the transaction should revert with Access Control", async () => {
        await expect(tx).to.be.revertedWith("AccessControl");
      });
    });
  });

  describe("GIVEN the ADMIN/owner user", () => {
    beforeEach(async () => {
      exactlyEnv.switchWallet(owner);
    });

    it("WHEN trying to enable a market for the second time, THEN the transaction should revert with MARKET_ALREADY_LISTED", async () => {
      let tx = exactlyEnv.enableMarket(
        exactlyEnv.getFixedLender("DAI").address,
        parseUnits("0"),
        "DAI",
        "DAI",
        mockedTokens.get("DAI")!.decimals
      );
      await expect(tx).to.be.revertedWith(
        errorGeneric(ProtocolError.MARKET_ALREADY_LISTED)
      );
    });

    it("WHEN trying to set a new fixedLender with a different auditor, THEN the transaction should revert with AUDITOR_MISMATCH", async () => {
      const newAuditor = await exactlyEnv.deployDuplicatedAuditor();
      const eToken = await exactlyEnv.deployNewEToken("eDAI", "Exa DAI", 18);

      const fixedLender = await exactlyEnv.deployNewFixedLender(
        eToken.address,
        newAuditor.address,
        exactlyEnv.interestRateModel.address,
        exactlyEnv.getUnderlying("DAI").address,
        "DAI"
      );

      let tx = exactlyEnv.enableMarket(
        fixedLender.address,
        parseUnits("0"),
        "Parallel DAI",
        "Parallel DAI",
        mockedTokens.get("DAI")!.decimals
      );

      await expect(tx).to.be.revertedWith(
        errorGeneric(ProtocolError.AUDITOR_MISMATCH)
      );
    });

    it("WHEN trying to set borrow caps on an unlisted market, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      let tx = exactlyEnv.auditor.setMarketBorrowCaps(
        [exactlyEnv.notAnFixedLenderAddress],
        [parseUnits("1000")]
      );
      await expect(tx).to.be.revertedWith(
        errorGeneric(ProtocolError.MARKET_NOT_LISTED)
      );
    });

    it("WHEN trying to set borrow caps with arguments mismatch, THEN the transaction should revert with INVALID_SET_BORROW_CAP", async () => {
      let tx = exactlyEnv.auditor.setMarketBorrowCaps(
        [exactlyEnv.getFixedLender("DAI").address],
        []
      );
      await expect(tx).to.be.revertedWith(
        errorGeneric(ProtocolError.INVALID_SET_BORROW_CAP)
      );
    });

    it("WHEN trying to retrieve all markets, THEN the addresses should match the ones passed on deploy", async () => {
      let addresses = await auditor.getMarketAddresses();
      expect(addresses[0]).to.equal(exactlyEnv.getFixedLender("DAI").address);
      expect(addresses[1]).to.equal(exactlyEnv.getFixedLender("WETH").address);
    });

    it("WHEN trying to set a new market, THEN the auditor should emit MarketListed event", async () => {
      const eToken = await exactlyEnv.deployNewEToken("eETH", "eETH", 18);
      const fixedLender = await exactlyEnv.deployNewFixedLender(
        eToken.address,
        exactlyEnv.auditor.address,
        exactlyEnv.interestRateModel.address,
        exactlyEnv.getUnderlying("WETH").address,
        "WETH"
      );

      let fixedLenderAddress = fixedLender.address;
      let tx = exactlyEnv.enableMarket(
        fixedLender.address,
        parseUnits("0.5"),
        "WETH",
        "WETH",
        18
      );

      await expect(tx)
        .to.emit(exactlyEnv.auditor, "MarketListed")
        .withArgs(fixedLenderAddress);
    });

    it("WHEN setting new oracle, THEN the auditor should emit OracleChanged event", async () => {
      let tx = await exactlyEnv.setOracle(exactlyEnv.oracle.address);
      await expect(tx).to.emit(exactlyEnv.auditor, "OracleChanged");
    });

    it("WHEN setting max borrow caps, THEN the auditor should emit NewBorrowCap event", async () => {
      let tx = await exactlyEnv.setBorrowCaps(["DAI"], ["10000"]);
      await expect(tx).to.emit(exactlyEnv.auditor, "NewBorrowCap");
    });

    it("WHEN setting exa speed, THEN the auditor should emit ExaSpeedUpdated event", async () => {
      let tx = await exactlyEnv.setExaSpeed("DAI", "10000");
      await expect(tx).to.emit(exactlyEnv.auditor, "ExaSpeedUpdated");
    });

    it("WHEN initializing a poolAccounting contract, THEN it should revert with CONTRACT_ALREADY_INITIALIZED", async () => {
      await expect(
        exactlyEnv.getPoolAccounting("DAI").initialize(owner.address)
      ).to.be.revertedWith(
        errorGeneric(ProtocolError.CONTRACT_ALREADY_INITIALIZED)
      );
    });

    describe("GIVEN Exa speed is 10000 for fixedLender for DAI", async () => {
      beforeEach(async () => {
        await exactlyEnv.setExaSpeed("DAI", "10000");
      });
      describe("WHEN setting exa speed to 10000 for fixedLender for DAI again", async () => {
        let tx: any;
        beforeEach(async () => {
          tx = await exactlyEnv.setExaSpeed("DAI", "10000");
        });

        it("THEN an ExaSpeedEvent is not emitted", async () => {
          await expect(tx).to.not.emit(exactlyEnv.auditor, "ExaSpeedUpdated");
        });
      });
    });

    describe("WHEN setting exa speed on an invalid fixedLender address", async () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.auditor.setExaSpeed(
          exactlyEnv.notAnFixedLenderAddress,
          parseUnits("1")
        );
      });

      it("THEN the auditor should NOT emit ExaSpeedUpdated event", async () => {
        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.MARKET_NOT_LISTED)
        );
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
