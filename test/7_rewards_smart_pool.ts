import { ethers } from "hardhat";
import { expect } from "chai";
import { Contract } from "ethers";
import { DefaultEnv, ExactlyEnv, RewardsLibEnv } from "./exactlyUtils";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("ExaToken Smart Pool", () => {
  let exactlyEnv: DefaultEnv;
  let rewardsLibEnv: RewardsLibEnv;
  let snapshot: any;

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
    [
      "WBTC",
      {
        decimals: 8,
        collateralRate: parseUnits("0.6"),
        usdPrice: parseUnits("63000"),
      },
    ],
  ]);

  let mariaUser: SignerWithAddress;
  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    exactlyEnv = await ExactlyEnv.create(mockedTokens);
    rewardsLibEnv = await ExactlyEnv.createRewardsEnv();
    [, mariaUser] = await ethers.getSigners();
  });

  describe("Integration", () => {
    let dai: Contract;
    let exafinDAI: Contract;
    let eDAI: Contract;
    let auditor: Contract;
    let exaToken: Contract;

    beforeEach(async () => {
      dai = exactlyEnv.getUnderlying("DAI");
      exafinDAI = exactlyEnv.getExafin("DAI");
      eDAI = exactlyEnv.getEToken("DAI");
      auditor = exactlyEnv.auditor;
      exaToken = exactlyEnv.exaToken;
      await eDAI.setExafin(exafinDAI.address);

      // From Owner to User
      await dai.transfer(mariaUser.address, parseUnits("1000"));
    });

    describe("Exafin-Auditor-ExaLib integration", () => {
      beforeEach(async () => {
        await auditor.setExaSpeed(exafinDAI.address, parseUnits("0.5"));
        await dai.transfer(mariaUser.address, parseUnits("1000"));
        await exaToken.transfer(auditor.address, parseUnits("50"));
      });

      it("should retrieve all rewards when calling claimExaAll", async () => {
        const underlyingAmount = parseUnits("100");
        await dai
          .connect(mariaUser)
          .approve(exafinDAI.address, underlyingAmount);

        let balanceUserPre = await exaToken
          .connect(mariaUser)
          .balanceOf(mariaUser.address);

        await exafinDAI.connect(mariaUser).depositToSmartPool(underlyingAmount);
        await auditor.connect(mariaUser).claimExaAll(mariaUser.address);

        let balanceUserPost = await exaToken
          .connect(mariaUser)
          .balanceOf(mariaUser.address);

        expect(balanceUserPre).to.equal(0);
        expect(balanceUserPost).to.not.equal(0);
      });

      it("should emit DistributedSmartPoolExa event when depositing to smart pool", async () => {
        const underlyingAmount = parseUnits("100");
        await dai.approve(exafinDAI.address, underlyingAmount);

        await expect(exafinDAI.depositToSmartPool(underlyingAmount)).to.emit(
          auditor,
          "DistributedSmartPoolExa"
        );
      });

      it("should DistributedSmartPoolExa when withdrawing from smart pool", async () => {
        // connect through Maria
        let exafinMaria = exafinDAI.connect(mariaUser);
        let underlyingTokenUser = dai.connect(mariaUser);
        let depositAmount = parseUnits("1");

        // supply some money and parse event
        await underlyingTokenUser.approve(exafinMaria.address, depositAmount);
        await exafinMaria.depositToSmartPool(depositAmount);

        await expect(exafinMaria.withdrawFromSmartPool(depositAmount)).to.emit(
          auditor,
          "DistributedSmartPoolExa"
        );
      });
    });
  });

  describe("updateExaSmartPoolIndex", () => {
    let auditorHarness: Contract;
    let exafinHarness: Contract;

    beforeEach(async () => {
      auditorHarness = rewardsLibEnv.auditorHarness;
      exafinHarness = rewardsLibEnv.exafinHarness;
    });

    it("should calculate EXA smart pool index correctly", async () => {
      let amountToDeposit = parseUnits("10");
      let blocksDelta = 100;

      // Call exaSpeed and jump blocksDelta
      await auditorHarness.setBlockNumber(0);
      await auditorHarness.setExaSpeed(
        exafinHarness.address,
        parseUnits("0.5")
      );
      await auditorHarness.setBlockNumber(blocksDelta);
      await exafinHarness.setTotalSmartPoolDeposits(
        mariaUser.address,
        amountToDeposit
      );
      await auditorHarness.updateExaSmartPoolIndex(exafinHarness.address);
      const [newIndex] = await auditorHarness.getSmartState(
        exafinHarness.address
      );

      let exaAccruedDelta = parseUnits("0.5").mul(blocksDelta);
      let ratioDelta = exaAccruedDelta
        .mul(parseUnits("1", 36))
        .div(amountToDeposit);

      let newIndexCalculated = parseUnits("1", 36).add(ratioDelta);
      expect(newIndex).to.be.equal(newIndexCalculated);
    });

    it("should not update index if no blocks passed since last accrual", async () => {
      await auditorHarness.setBlockNumber(0);
      await auditorHarness.setExaSpeed(
        exafinHarness.address,
        parseUnits("0.5")
      );
      await exafinHarness.setTotalSmartPoolDeposits(
        mariaUser.address,
        parseUnits("10000")
      );
      await auditorHarness.updateExaSmartPoolIndex(exafinHarness.address);

      const [newIndex, block] = await auditorHarness.getSmartState(
        exafinHarness.address
      );
      expect(newIndex).to.equal(parseUnits("1", 36));
      expect(block).to.equal(0);
    });

    it("should not update index if EXA speed is 0", async () => {
      // Update borrows
      await auditorHarness.setBlockNumber(0);
      await auditorHarness.setExaSpeed(
        exafinHarness.address,
        parseUnits("0.5")
      );
      await auditorHarness.setBlockNumber(100);
      await auditorHarness.setExaSpeed(exafinHarness.address, 0);
      await exafinHarness.setTotalSmartPoolDeposits(
        mariaUser.address,
        parseUnits("10000")
      );
      await auditorHarness.updateExaSmartPoolIndex(exafinHarness.address);

      const [newIndex, block] = await auditorHarness.getSmartState(
        exafinHarness.address
      );
      expect(newIndex).to.equal(parseUnits("1", 36));
      expect(block).to.equal(100);
    });
  });

  describe("distributeSmartPoolExa", () => {
    let auditorHarness: Contract;
    let exafinHarness: Contract;
    let exaToken: Contract;

    beforeEach(async () => {
      auditorHarness = rewardsLibEnv.auditorHarness;
      exafinHarness = rewardsLibEnv.exafinHarness;
      exaToken = rewardsLibEnv.exaToken;
    });

    it("should transfer EXA and update smart pool index correctly for first time user", async () => {
      await exaToken.transfer(auditorHarness.address, parseUnits("50"));
      await exafinHarness.setTotalSmartPoolDeposits(
        mariaUser.address,
        parseUnits("5")
      );
      await auditorHarness.setExaSmartState(
        exafinHarness.address,
        parseUnits("6", 36),
        10
      );
      let tx = await auditorHarness.distributeAllSmartPoolExa(
        exafinHarness.address,
        mariaUser.address
      );
      let accrued = await auditorHarness.getExaAccrued(mariaUser.address);
      let balance = await exaToken.balanceOf(mariaUser.address);
      expect(accrued).to.equal(0);
      expect(balance).to.equal(parseUnits("25"));
      expect(tx)
        .to.emit(auditorHarness, "DistributedSmartPoolExa")
        .withArgs(
          exafinHarness.address,
          mariaUser.address,
          parseUnits("25"),
          parseUnits("6", 36)
        );
    });

    it("should update EXA accrued and smart index for repeat user", async () => {
      await exaToken.transfer(auditorHarness.address, parseUnits("50"));
      await exafinHarness.setTotalSmartPoolDeposits(
        mariaUser.address,
        parseUnits("5")
      );
      await auditorHarness.setExaSmartState(
        exafinHarness.address,
        parseUnits("6", 36),
        10
      );
      await auditorHarness.setExaSmartSupplierIndex(
        exafinHarness.address,
        mariaUser.address,
        parseUnits("2", 36)
      );
      /**
       * supplierAmount  = 5e18
       * deltaIndex      = marketStoredIndex - userStoredIndex
       *                 = 6e36 - 2e36 = 4e36
       * suppliedAccrued+= supplierTokens * deltaIndex / 1e36
       *                 = 5e18 * 4e36 / 1e36 = 20e18
       */
      await auditorHarness.distributeAllSmartPoolExa(
        exafinHarness.address,
        mariaUser.address
      );
      let accrued = await auditorHarness.getExaAccrued(mariaUser.address);
      let balance = await exaToken.balanceOf(mariaUser.address);
      expect(accrued).to.equal(0);
      expect(balance).to.equal(parseUnits("20"));
    });

    it("should not transfer EXA automatically", async () => {
      await exaToken.transfer(auditorHarness.address, parseUnits("50"));
      await exafinHarness.setTotalSmartPoolDeposits(
        mariaUser.address,
        parseUnits("0.5")
      );
      await auditorHarness.setExaSmartState(
        exafinHarness.address,
        parseUnits("1.0019", 36),
        10
      );
      await auditorHarness.distributeSmartPoolExa(
        exafinHarness.address,
        mariaUser.address
      );
      let accrued = await auditorHarness.getExaAccrued(mariaUser.address);
      let balance = await exaToken.balanceOf(mariaUser.address);
      expect(accrued).to.equal(parseUnits("0.00095"));
      expect(balance).to.equal(0);
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
