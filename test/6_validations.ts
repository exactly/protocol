import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import {
  ProtocolError,
  errorGeneric,
  ExaTime,
  errorUnmatchedPool,
  PoolState,
} from "./exactlyUtils";
import { DefaultEnv } from "./defaultEnv";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Validations", function () {
  let auditor: Contract;
  let unlistedFixedLender: Contract;
  let fixedLender: Contract;
  let exactlyEnv: DefaultEnv;

  let owner: SignerWithAddress;
  let user: SignerWithAddress;
  const exaTime: ExaTime = new ExaTime();
  const nextPoolId: number = exaTime.nextPoolID();

  before(async () => {
    [owner, user] = await ethers.getSigners();

    exactlyEnv = await DefaultEnv.create({});
    auditor = exactlyEnv.auditor;
    fixedLender = exactlyEnv.getFixedLender("DAI");

    const UnlistedFixedLender = await ethers.getContractFactory("FixedLender");
    unlistedFixedLender = await UnlistedFixedLender.deploy(
      exactlyEnv.getUnderlying("DAI").address,
      "DAI",
      exactlyEnv.getEToken("DAI").address,
      auditor.address,
      exactlyEnv.getPoolAccounting("DAI").address
    );
    await unlistedFixedLender.deployed();
  });

  describe("Auditor: GIVEN an unlisted market as parameter", () => {
    it("WHEN trying to enter markets, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(
        auditor.enterMarkets([exactlyEnv.notAnFixedLenderAddress])
      ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
    });
    it("WHEN trying to exit market, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(
        auditor.exitMarket(exactlyEnv.notAnFixedLenderAddress)
      ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
    });
    it("WHEN trying to set borrow caps, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(
        auditor.setMarketBorrowCaps(
          [exactlyEnv.notAnFixedLenderAddress],
          [parseUnits("1000")]
        )
      ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
    });
    it("WHEN trying to call liquidateAllowed, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(
        auditor.liquidateAllowed(
          exactlyEnv.notAnFixedLenderAddress,
          fixedLender.address,
          owner.address,
          user.address,
          100
        )
      ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
      await expect(
        auditor.liquidateAllowed(
          fixedLender.address,
          exactlyEnv.notAnFixedLenderAddress,
          owner.address,
          user.address,
          100
        )
      ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
    });
    it("WHEN trying to call seizeAllowed, THEN the transaction should revert with MARKET_NOT_LISTED", async () => {
      await expect(
        auditor.seizeAllowed(
          exactlyEnv.notAnFixedLenderAddress,
          fixedLender.address,
          owner.address,
          user.address
        )
      ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
      await expect(
        auditor.seizeAllowed(
          fixedLender.address,
          exactlyEnv.notAnFixedLenderAddress,
          owner.address,
          user.address
        )
      ).to.be.revertedWith(errorGeneric(ProtocolError.MARKET_NOT_LISTED));
    });
  });
  describe("FixedLender:", () => {
    describe("GIVEN a NOT matured pool", () => {
      it("WHEN trying to withdraw from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(
          exactlyEnv.withdrawMP("DAI", nextPoolId, "100")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.VALID, PoolState.MATURED)
        );
      });
    });
    describe("GIVEN a NOT not-yet-enabled pool", () => {
      it("WHEN trying to deposit to MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(
          exactlyEnv.depositMP("DAI", exaTime.distantFuturePoolID(), "100")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID)
        );
      });
      it("WHEN trying to borrow from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(
          exactlyEnv.borrowMP("DAI", exaTime.distantFuturePoolID(), "2", "2")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.NOT_READY, PoolState.VALID)
        );
      });
      it("WHEN trying to withdraw from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(
          exactlyEnv.withdrawMP("DAI", exaTime.distantFuturePoolID(), "100")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.NOT_READY, PoolState.MATURED)
        );
      });
      it("WHEN trying to repay to MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(
          exactlyEnv.repayMP("DAI", exaTime.distantFuturePoolID(), "100")
        ).to.be.revertedWith(
          "UnmatchedPoolStateMultiple(" +
            PoolState.NOT_READY +
            ", " +
            PoolState.VALID +
            ", " +
            PoolState.MATURED +
            ")"
        );
      });
    });
    describe("GIVEN a matured pool", () => {
      it("WHEN trying to deposit to MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(
          exactlyEnv.depositMP("DAI", exaTime.pastPoolID(), "100")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.MATURED, PoolState.VALID)
        );
      });
      it("WHEN trying to borrow from MP, THEN the transaction should revert with UnmatchedPoolState error", async () => {
        await expect(
          exactlyEnv.borrowMP("DAI", exaTime.pastPoolID(), "3", "3")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.MATURED, PoolState.VALID)
        );
      });
    });
    describe("GIVEN an invalid pool id", () => {
      it("WHEN trying to deposit to MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(
          exactlyEnv.depositMP("DAI", exaTime.invalidPoolID(), "100")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.INVALID, PoolState.VALID)
        );
      });
      it("WHEN trying to borrow from MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(
          exactlyEnv.borrowMP("DAI", exaTime.invalidPoolID(), "3", "3")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.INVALID, PoolState.VALID)
        );
      });
      it("WHEN trying to withdraw from MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(
          exactlyEnv.withdrawMP("DAI", exaTime.invalidPoolID(), "100")
        ).to.be.revertedWith(
          errorUnmatchedPool(PoolState.INVALID, PoolState.MATURED)
        );
      });
      it("WHEN trying to repay to MP, THEN it reverts with UnmatchedPoolState error", async () => {
        await expect(
          exactlyEnv.repayMP("DAI", exaTime.invalidPoolID(), "100")
        ).to.be.revertedWith(
          "UnmatchedPoolStateMultiple(" +
            PoolState.INVALID +
            ", " +
            PoolState.VALID +
            ", " +
            PoolState.MATURED +
            ")"
        );
      });
    });
  });
});