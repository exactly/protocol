import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { ProtocolError, ExactlyEnv, errorGeneric } from "./exactlyUtils";
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
      "ETH",
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

    exactlyEnv = await ExactlyEnv.create({ mockedTokens });
    auditor = exactlyEnv.auditor;

    await exactlyEnv.transfer("DAI", laura, "10000");

    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  describe("GIVEN a regular user", () => {
    beforeEach(async () => {
      exactlyEnv.switchWallet(laura);
    });

    describe("WHEN trying to enable a market", async () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.enableMarket(
          exactlyEnv.getFixedLender("DAI").address,
          parseUnits("0"),
          "DAI",
          "DAI",
          mockedTokens.get("DAI")!.decimals
        );
      });

      it("THEN the transaction should revert with Access Control", async () => {
        await expect(tx).to.be.revertedWith("AccessControl");
      });
    });

    describe("WHEN trying to set liquidation incentive", async () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.setLiquidationIncentive("1.01");
      });

      it("THEN the transaction should revert with Access Control", async () => {
        await expect(tx).to.be.revertedWith("AccessControl");
      });
    });

    describe("WHEN trying to set a new oracle", async () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.setOracle(exactlyEnv.oracle.address);
      });

      it("THEN the transaction should revert with Access Control", async () => {
        await expect(tx).to.be.revertedWith("AccessControl");
      });
    });

    describe("WHEN trying to set borrow caps", async () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.setBorrowCaps(["DAI"], ["1000000"]);
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

    describe("WHEN trying to enable a market for the second time", async () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.enableMarket(
          exactlyEnv.getFixedLender("DAI").address,
          parseUnits("0"),
          "DAI",
          "DAI",
          mockedTokens.get("DAI")!.decimals
        );
      });

      it("THEN the transaction should revert with MARKET_ALREADY_LISTED", async () => {
        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.MARKET_ALREADY_LISTED)
        );
      });
    });

    describe("WHEN trying to set a new fixedLender with a different auditor", async () => {
      let tx: any;
      beforeEach(async () => {
        const newAuditor = await exactlyEnv.createDeployDuplicatedAuditor();
        const eToken = await exactlyEnv.createDeployNewEToken(
          "eDAI",
          "Exa DAI",
          18
        );

        const fixedLender = await exactlyEnv.createDeployNewFixedLender(
          eToken.address,
          newAuditor.address,
          exactlyEnv.interestRateModel.address,
          exactlyEnv.getUnderlying("DAI").address,
          "DAI"
        );

        tx = exactlyEnv.enableMarket(
          fixedLender.address,
          parseUnits("0"),
          "Parallel DAI",
          "Parallel DAI",
          mockedTokens.get("DAI")!.decimals
        );
      });

      it("THEN the transaction should revert with AUDITOR_MISMATCH", async () => {
        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.AUDITOR_MISMATCH)
        );
      });
    });

    describe("WHEN trying to set borrow caps on an unlisted market", async () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.auditor.setMarketBorrowCaps(
          [exactlyEnv.notAnFixedLenderAddress],
          [parseUnits("1000")]
        );
      });

      it("THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.MARKET_NOT_LISTED)
        );
      });
    });

    describe("WHEN trying to set borrow caps with arguments mismatch", async () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.auditor.setMarketBorrowCaps(
          [exactlyEnv.getFixedLender("DAI").address],
          []
        );
      });

      it("THEN the transaction should revert with INVALID_SET_BORROW_CAP", async () => {
        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.INVALID_SET_BORROW_CAP)
        );
      });
    });

    describe("WHEN trying to retrieve all markets", async () => {
      let addresses: string[];
      beforeEach(async () => {
        addresses = await auditor.getMarketAddresses();
      });

      it("THEN the addresses should match the ones passed on deploy", async () => {
        expect(addresses[0]).to.equal(exactlyEnv.getFixedLender("DAI").address);
        expect(addresses[1]).to.equal(exactlyEnv.getFixedLender("ETH").address);
      });
    });

    describe("WHEN trying to set a new market", async () => {
      let tx: any;
      let fixedLenderAddress: string;
      beforeEach(async () => {
        const eToken = await exactlyEnv.createDeployNewEToken(
          "eETH",
          "eETH",
          18
        );
        const fixedLender = await exactlyEnv.createDeployNewFixedLender(
          eToken.address,
          exactlyEnv.auditor.address,
          exactlyEnv.interestRateModel.address,
          exactlyEnv.getUnderlying("ETH").address,
          "ETH"
        );

        fixedLenderAddress = fixedLender.address;
        tx = exactlyEnv.enableMarket(
          fixedLender.address,
          parseUnits("0.5"),
          "ETH",
          "ETH",
          18
        );
      });

      it("THEN the auditor should emit MarketListed event", async () => {
        await expect(tx)
          .to.emit(exactlyEnv.auditor, "MarketListed")
          .withArgs(fixedLenderAddress);
      });
    });

    describe("WHEN setting new oracle", async () => {
      let tx: any;
      beforeEach(async () => {
        tx = await exactlyEnv.setOracle(exactlyEnv.oracle.address);
      });

      it("THEN the auditor should emit OracleChanged event", async () => {
        await expect(tx).to.emit(exactlyEnv.auditor, "OracleChanged");
      });
    });

    describe("WHEN setting max borrow caps", async () => {
      let tx: any;
      beforeEach(async () => {
        tx = await exactlyEnv.setBorrowCaps(["DAI"], ["10000"]);
      });

      it("THEN the auditor should emit NewBorrowCap event", async () => {
        await expect(tx).to.emit(exactlyEnv.auditor, "NewBorrowCap");
      });
    });

    describe("WHEN setting exa speed", async () => {
      let tx: any;
      beforeEach(async () => {
        tx = await exactlyEnv.setExaSpeed("DAI", "10000");
      });

      it("THEN the auditor should emit ExaSpeedUpdated event", async () => {
        await expect(tx).to.emit(exactlyEnv.auditor, "ExaSpeedUpdated");
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
