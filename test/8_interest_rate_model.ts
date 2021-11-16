import { expect } from "chai";
import { ethers } from "hardhat";
import { formatUnits, parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { ExactlyEnv, ExaTime, DefaultEnv } from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { parseEther } from "ethers/lib/utils";

describe("InterestRateModel", () => {
  let exactlyEnv: DefaultEnv;

  let underlyingToken: Contract;
  let eth: Contract;
  let interestRateModel: Contract;

  function truncDigits(inputNumber: number, digits: number): number {
    const fact = 10 ** digits;
    return Math.floor(inputNumber * fact) / fact;
  }

  const mockedTokens = new Map([
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
        usdPrice: parseUnits("3100"),
      },
    ],
  ]);

  let mariaUser: SignerWithAddress;
  let exaTime: ExaTime;

  let snapshot: any;
  let futurePool: number;

  let maturityPool = {
    borrowed: 0,
    supplied: 0,
    debt: 0,
    available: 0,
  };

  let smartPool = {
    borrowed: 0,
    supplied: 0,
  };

  let mpSlopeRate: number = 0.07;
  let spSlopeRate: number = 0.07;
  let spHighURSlopeRate: number = 0.4;
  let baseRate: number = 0.02;

  const closeToRate = 1 * 10 ** -17;

  beforeEach(async () => {
    maturityPool = {
      borrowed: 0,
      supplied: 0,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 0,
      supplied: 0,
    };
    [mariaUser] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(mockedTokens);

    underlyingToken = exactlyEnv.getUnderlying("DAI");
    eth = exactlyEnv.getUnderlying("ETH");

    interestRateModel = exactlyEnv.interestRateModel;
    // From Owner to User
    underlyingToken.transfer(mariaUser.address, parseUnits("1000000"));
    eth.transfer(mariaUser.address, parseEther("100"));
    exaTime = new ExaTime();

    futurePool = exaTime.futurePools(2)[1];

    // This can be optimized (so we only do it once per file, not per test)
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });

  it("With well funded Smart pool, supply 1 to Maturity Pool, borrow 2 from maturity pool, borrow 2 from maturity pool. Should get Maturity pool rate", async () => {
    maturityPool = {
      borrowed: 4,
      supplied: 4,
      debt: 3,
      available: 0,
    };

    smartPool = {
      borrowed: 3,
      supplied: 100000,
    };

    const yearlyRateMaturity =
      baseRate + (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;

    const rate = truncDigits(
      (yearlyRateMaturity * exaTime.daysDiffWith(futurePool)) / 365,
      18
    );
    const actual = formatUnits(
      await interestRateModel.getRateToBorrow(
        futurePool,
        maturityPool,
        smartPool,
        true
      )
    );

    expect(parseFloat(actual)).to.be.closeTo(rate, closeToRate);
  });

  it("With well funded Smart pool, supply 10000 to Maturity Pool, borrow 10000 from maturity pool. Should get Maturity pool rate", async () => {
    maturityPool = {
      borrowed: 10000,
      supplied: 10000,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 10000,
      supplied: 110000,
    };

    const yearlyRateMaturity =
      baseRate + (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;

    const rate = truncDigits(
      (yearlyRateMaturity * exaTime.daysDiffWith(futurePool)) / 365,
      18
    );
    const actual = formatUnits(
      await interestRateModel.getRateToBorrow(
        futurePool,
        maturityPool,
        smartPool,
        true
      )
    );

    expect(parseFloat(actual)).to.be.closeTo(rate, closeToRate);
  });

  it("With well funded Smart pool, borrow 10000 from maturity pool. Should get Maturity pool rate", async () => {
    maturityPool = {
      borrowed: 10000,
      supplied: 10000,
      debt: 10000,
      available: 0,
    };

    smartPool = {
      borrowed: 10000,
      supplied: 100000,
    };

    const yearlyRateMaturity =
      baseRate + (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;

    const rate = truncDigits(
      (yearlyRateMaturity * exaTime.daysDiffWith(futurePool)) / 365,
      18
    );
    const actual = formatUnits(
      await interestRateModel.getRateToBorrow(
        futurePool,
        maturityPool,
        smartPool,
        true
      )
    );

    expect(parseFloat(actual)).to.be.closeTo(rate, closeToRate);
  });

  it("With well funded Smart pool, borrow 10000 from maturity pool, after that borrow 10000 again. Should get Maturity pool rate in both cases", async () => {
    maturityPool = {
      borrowed: 10000,
      supplied: 10000,
      debt: 10000,
      available: 0,
    };

    smartPool = {
      borrowed: 10000,
      supplied: 100000,
    };

    const yearlyRateMaturity =
      baseRate + (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;

    const rate = truncDigits(
      (yearlyRateMaturity * exaTime.daysDiffWith(futurePool)) / 365,
      18
    );
    const actual = formatUnits(
      await interestRateModel.getRateToBorrow(
        futurePool,
        maturityPool,
        smartPool,
        true
      )
    );

    expect(parseFloat(actual)).to.be.closeTo(rate, closeToRate);

    maturityPool = {
      borrowed: 20000,
      supplied: 20000,
      debt: 20000,
      available: 0,
    };

    smartPool = {
      borrowed: 20000,
      supplied: 100000,
    };

    expect(parseFloat(actual)).to.be.closeTo(rate, closeToRate);
  });

  it("Borrow less than supplied in maturity pool", async () => {
    maturityPool = {
      borrowed: 20,
      supplied: 10000,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 0,
      supplied: 10000,
    };

    const yearlyRateMaturity =
      baseRate + (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;

    const rate = truncDigits(
      (yearlyRateMaturity * exaTime.daysDiffWith(futurePool)) / 365,
      18
    );
    const actual = formatUnits(
      await interestRateModel.getRateToBorrow(
        futurePool,
        maturityPool,
        smartPool,
        true
      )
    );

    expect(parseFloat(actual)).to.be.closeTo(rate, closeToRate);
  });

  it("Borrow less than supplied in maturity pool, then supply some more tokens", async () => {
    maturityPool = {
      borrowed: 10,
      supplied: 10010,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 0,
      supplied: 10000,
    };

    const yearlyRateMaturity =
      baseRate + (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;

    const rate = truncDigits(
      (yearlyRateMaturity * exaTime.daysDiffWith(futurePool)) / 365,
      18
    );
    const actual = formatUnits(
      await interestRateModel.getRateToSupply(futurePool, maturityPool)
    );

    expect(parseFloat(actual)).to.be.closeTo(rate, closeToRate);
  });

  it("Supply into an empty maturity pool when smart pool UR is near to 75%, then borrow half of the amount you supply", async () => {
    maturityPool = {
      borrowed: 0,
      supplied: 100000,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 3000000,
      supplied: 4000000,
    };

    const yearlyRateMaturity =
      baseRate + (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;

    const rate = truncDigits(
      (yearlyRateMaturity * exaTime.daysDiffWith(futurePool)) / 365,
      18
    );

    const actual = formatUnits(
      await interestRateModel.getRateToSupply(futurePool, maturityPool)
    );

    expect(parseFloat(actual)).to.be.closeTo(rate, closeToRate);

    maturityPool = {
      borrowed: 50000,
      supplied: 100000,
      debt: 0,
      available: 0,
    };

    const yearlyRateMaturity2 =
      baseRate + (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;

    const rate2 = truncDigits(
      (yearlyRateMaturity2 * exaTime.daysDiffWith(futurePool)) / 365,
      18
    );

    const actual2 = formatUnits(
      await interestRateModel.getRateToBorrow(
        futurePool,
        maturityPool,
        smartPool,
        false
      )
    );

    expect(parseFloat(actual2)).to.be.closeTo(rate2, closeToRate);
    expect(parseFloat(actual2)).to.be.above(parseFloat(actual));
  });

  it("Deposits to empty maturity pool, makes flash loan and deposit all of it to smart pool, borrow from maturity pool all collateral, pays flash loan", async () => {
    maturityPool = {
      borrowed: 0,
      supplied: 226213,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 3000000,
      supplied: 4000000,
    };

    const yearlyRateMaturity =
      baseRate + (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;

    const rate = truncDigits(
      (yearlyRateMaturity * exaTime.daysDiffWith(futurePool)) / 365,
      18
    );

    const actual = formatUnits(
      await interestRateModel.getRateToSupply(futurePool, maturityPool)
    );

    expect(parseFloat(actual)).to.be.closeTo(rate, closeToRate);

    maturityPool = {
      borrowed: 150000,
      supplied: 226213,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 0,
      supplied: 100000000000000,
    };

    const yearlyRateMaturity2 =
      baseRate + (mpSlopeRate * maturityPool.borrowed) / maturityPool.supplied;

    const rate2 = truncDigits(
      (yearlyRateMaturity2 * exaTime.daysDiffWith(futurePool)) / 365,
      18
    );

    const actual2 = formatUnits(
      await interestRateModel.getRateToBorrow(
        futurePool,
        maturityPool,
        smartPool,
        false
      )
    );

    expect(parseFloat(actual2)).to.be.closeTo(rate2, closeToRate);
    expect(parseFloat(actual2)).to.be.above(parseFloat(actual));
  });

  it("Borrow 10 from maturity pool with no money in maturity pool nor smart pool", async () => {
    maturityPool = {
      borrowed: 10,
      supplied: 0,
      debt: 0,
      available: 0,
    };

    smartPool = {
      borrowed: 0,
      supplied: 0,
    };

    expect(
      formatUnits(
        await interestRateModel.getRateToBorrow(
          futurePool,
          maturityPool,
          smartPool,
          true
        )
      )
    ).to.be.equal("0.0");
  });

  it("Borrow more than supplied in maturity pool with high UR in smart pool. Should get high slope", async () => {
    maturityPool = {
      borrowed: 2,
      supplied: 1,
      debt: 1,
      available: 0,
    };

    smartPool = {
      borrowed: 901,
      supplied: 1000,
    };

    const actual = formatUnits(
      await interestRateModel.getRateToBorrow(
        futurePool,
        maturityPool,
        smartPool,
        true
      )
    );

    const yearlyRateSmartHighUR =
      (spHighURSlopeRate * smartPool.borrowed) / smartPool.supplied;

    const rate = truncDigits(
      (yearlyRateSmartHighUR * exaTime.daysDiffWith(futurePool)) / 365,
      18
    );

    expect(parseFloat(actual)).to.be.closeTo(rate, closeToRate);
  });

  it("Borrow more than supplied in maturity pool with high UR in smart pool. Should get high slope", async () => {
    maturityPool = {
      borrowed: 2,
      supplied: 1,
      debt: 1,
      available: 0,
    };

    smartPool = {
      borrowed: 901,
      supplied: 1000,
    };

    const actual = formatUnits(
      await interestRateModel.getRateToBorrow(
        futurePool,
        maturityPool,
        smartPool,
        true
      )
    );

    const yearlyRateSmartHighUR =
      (spHighURSlopeRate * smartPool.borrowed) / smartPool.supplied;

    const rate = truncDigits(
      (yearlyRateSmartHighUR * exaTime.daysDiffWith(futurePool)) / 365,
      18
    );

    expect(parseFloat(actual)).to.be.closeTo(rate, closeToRate);
  });
});
