import { expect } from "chai";
import { parseUnits } from "@ethersproject/units";
import { Contract, BigNumber } from "ethers";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ethers } from "hardhat";
import { expectFee } from "./exactlyUtils";
import { DefaultEnv } from "./defaultEnv";
import futurePools from "./utils/futurePools";

const nextPoolID = futurePools(1)[0].toNumber();
const secondPoolID = futurePools(2)[1].toNumber();
const thirdPoolID = futurePools(3)[2].toNumber();

describe("InterestRateModel", () => {
  let exactlyEnv: DefaultEnv;

  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;
  let interestRateModel: Contract;
  let snapshot: any;

  beforeEach(async () => {
    exactlyEnv = await DefaultEnv.create({ useRealInterestRateModel: true });
    [owner, alice, bob] = await ethers.getSigners();

    interestRateModel = exactlyEnv.interestRateModel;
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await exactlyEnv.takeSnapshot();
  });

  afterEach(async () => {
    await exactlyEnv.revertSnapshot(snapshot);
  });

  describe("setting different curve parameters", () => {
    it("WHEN deploying a contract with A and B parameters yielding an invalid FIXED curve THEN it reverts", async () => {
      // - U_{b}: 0.9
      // - U_{max}: 1.2
      // - R_{0}: -0.01
      // - R_{b}: 0.22

      // A = ((Umax*(Umax-Ub))/Ub)*(Rb-R0)
      // A = .09200000000000000000

      // B = ((Umax/Ub)*R0) + (1-(Umax/Ub))*Rb
      // B = -.08666666666666666666
      const A = parseUnits("0.092"); // A parameter for the curve
      const B = parseUnits("-0.086666666666666666"); // B parameter for the curve
      const fixedMaxUtilization = parseUnits("1.2"); // Maximum utilization rate
      const fixedFullUtilization = parseUnits("1"); // Full utilization rate
      const InterestRateModelFactory = await ethers.getContractFactory("InterestRateModel", {});
      const tx = InterestRateModelFactory.deploy(
        A, // A parameter for the curve
        B, // B parameter for the curve
        fixedMaxUtilization, // High UR slope rate
        fixedFullUtilization, // Full UR
        parseUnits("0.72"),
        parseUnits("-0.22"),
        parseUnits("3"),
        parseUnits("2"),
        0,
      );
      await expect(tx).to.be.reverted;
    });
    it("WHEN setting A and B parameters yielding an invalid FIXED curve THEN it reverts", async () => {
      // same as case above
      const A = parseUnits("0.092"); // A parameter for the curve
      const B = parseUnits("-0.086666666666666666"); // B parameter for the curve
      const fixedMaxUtilization = parseUnits("1.2"); // Maximum utilization rate
      const fixedFullUtilization = parseUnits("1"); // Full utilization rate
      const tx = interestRateModel.setFixedCurveParameters(A, B, fixedMaxUtilization, fixedFullUtilization);

      await expect(tx).to.be.reverted;
    });
    it("WHEN deploying a contract with A and B parameters yielding an invalid FLEXIBLE curve THEN it reverts", async () => {
      const A = parseUnits("0.092"); // A parameter for the curve
      const B = parseUnits("-0.086666666666666666"); // B parameter for the curve
      const flexibleMaxUtilization = parseUnits("1.2"); // Maximum utilization rate
      const flexibleFullUtilization = parseUnits("1"); // Full utilization rate
      const InterestRateModelFactory = await ethers.getContractFactory("InterestRateModel", {});
      const tx = InterestRateModelFactory.deploy(
        parseUnits("0.72"),
        parseUnits("-0.22"),
        parseUnits("3"),
        parseUnits("2"),
        A, // A parameter for the curve
        B, // B parameter for the curve
        flexibleMaxUtilization, // High UR slope rate
        flexibleFullUtilization, // Full UR
        0,
      );
      await expect(tx).to.be.reverted;
    });
    it("WHEN setting A and B parameters yielding an invalid FLEXIBLE curve THEN it reverts", async () => {
      // same as case above
      const A = parseUnits("0.092"); // A parameter for the curve
      const B = parseUnits("-0.086666666666666666"); // B parameter for the curve
      const flexibleMaxUtilization = parseUnits("1.2"); // Maximum utilization rate
      const flexibleFullUtilization = parseUnits("1"); // Full utilization rate
      const tx = interestRateModel.setFlexibleCurveParameters(A, B, flexibleMaxUtilization, flexibleFullUtilization);

      await expect(tx).to.be.reverted;
    });
    // - U_{b}: 0.9
    // - U_{max}: 1.2
    // - R_{0}: 0.02
    // - R_{b}: 0.22

    //     A = ((Umax*(Umax-Ub))/Ub)*(Rb-R0)
    //     A = .08000000000000000000

    //     B = ((Umax/Ub)*R0) + (1-(Umax/Ub))*Rb
    //     B = -.046666666666666666
    describe("WHEN changing the curve parameters to another valid curve with a different Ub, Umax and Rb", () => {
      const A = parseUnits("0.08"); // A parameter for the curve
      const B = parseUnits("-0.046666666666666666"); // B parameter for the curve
      const fixedMaxUtilization = parseUnits("1.2"); // Maximum utilization rate
      const fixedFullUtilization = parseUnits("1"); // Full utilization rate

      beforeEach(async () => {
        await interestRateModel.setFixedCurveParameters(A, B, fixedMaxUtilization, fixedFullUtilization);
      });
      it("THEN the new fixedMaxUtilization is readable", async () => {
        expect(await interestRateModel.fixedMaxUtilization()).to.be.equal(fixedMaxUtilization);
      });
      it("AND the curves R0 stayed the same", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 365 * 86_400, // force yearly calculation
          parseUnits("0.00000000000001"),
          parseUnits("0"),
          parseUnits("50"),
          parseUnits("50"),
        );
        expect(rate).to.gt(parseUnits("0.019"));
        expect(rate).to.lt(parseUnits("0.021"));
      });
      it("AND the curves Rb and Ub changed accordingly", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 365 * 86_400, // force yearly calculation
          parseUnits("0.00000000000001"),
          parseUnits("90"),
          parseUnits("50"),
          parseUnits("50"),
        );
        expect(rate).to.gt(parseUnits("0.21"));
        expect(rate).to.lt(parseUnits("0.23"));
      });
      it("AND the curves Umax changed", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 365 * 86_400, // force yearly calculation
          parseUnits("0.00000000000001"),
          parseUnits("99.99999999999999"), // if borrowed more than supply then UR after is invalid (more than fullUR)
          parseUnits("50"),
          parseUnits("50"),
        );
        expect(rate).to.gt(parseUnits("0.353"));
        expect(rate).to.lt(parseUnits("0.354"));
      });
    });

    describe("WHEN changing the curve parameters to another valid curve with a higher R0 of 0.05", () => {
      const A = parseUnits("0.037125"); // A parameter for the curve
      const B = parseUnits("0.01625"); // B parameter for the curve
      const fixedMaxUtilization = parseUnits("1.1"); // Maximum utilization rate
      const fixedFullUtilization = parseUnits("1"); // Full utilization rate

      beforeEach(async () => {
        await interestRateModel.setFixedCurveParameters(A, B, fixedMaxUtilization, fixedFullUtilization);
      });
      it("THEN the new parameters are readable", async () => {
        expect(await interestRateModel.fixedCurveA()).to.be.equal(A);
        expect(await interestRateModel.fixedCurveB()).to.be.equal(B);
        expect(await interestRateModel.fixedMaxUtilization()).to.be.equal(fixedMaxUtilization);
      });
      it("AND the curves R0 changed accordingly", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 365 * 86_400, // force yearly calculation
          parseUnits("0.000000000001"),
          parseUnits("0"),
          parseUnits("50"),
          parseUnits("50"),
        );
        expect(rate).to.gt(parseUnits("0.049"));
        expect(rate).to.lt(parseUnits("0.051"));
      });
      it("AND the curves Rb stays the same", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 365 * 86_400, // force yearly calculation
          parseUnits("0.0000000001"),
          parseUnits("80"),
          parseUnits("50"),
          parseUnits("50"),
        );
        expect(rate).to.gt(parseUnits("0.139"));
        expect(rate).to.lt(parseUnits("0.141"));
      });
    });
  });

  describe("dynamic use of SP liquidity", () => {
    describe("GIVEN 12k of SP liquidity AND enough collateral", () => {
      beforeEach(async () => {
        await exactlyEnv.depositSP("DAI", "12000");
        await exactlyEnv.transfer("WETH", alice, "30");
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.depositSP("WETH", "30");
        await exactlyEnv.enterMarket("WETH");
        await exactlyEnv.moveInTime(nextPoolID);
        exactlyEnv.switchWallet(owner);
      });
      describe("GIVEN curve parameters yielding Ub=1, Umax=3, R0=0.02 and Rb=0.14", () => {
        beforeEach(async () => {
          // A = ((Umax*(Umax-Ub))/Ub)*(Rb-R0)
          // A = ((3*(3-1))/1)*(0.14-0.02)
          // A = .72000000000000000000

          // B = ((Umax/Ub)*R0) + (1-(Umax/Ub))*Rb
          // B = ((3/1)*0.02) + (1-(3/1))*0.14
          // B = -.22000000000000000000

          const A = parseUnits("0.72"); // A parameter for the curve
          const B = parseUnits("-0.22"); // B parameter for the curve
          const fixedMaxUtilization = parseUnits("3"); // Maximum utilization rate
          const fixedFullUtilization = parseUnits("2"); // Full utilization rate
          await interestRateModel.setFixedCurveParameters(A, B, fixedMaxUtilization, fixedFullUtilization);
          exactlyEnv.switchWallet(alice);
        });
        it("WHEN doing a borrow which pushes U to 3.2, THEN it reverts because the utilization rate is too high", async () => {
          await expect(exactlyEnv.borrowMP("DAI", secondPoolID, "19200", "19200")).to.be.revertedWith(
            "UtilizationExceeded()",
          );
        });
        it("WHEN doing a borrow which pushes U to 6, THEN it reverts because the utilization rate is too high", async () => {
          await expect(exactlyEnv.borrowMP("DAI", secondPoolID, "36000", "36000")).to.be.revertedWith(
            "UtilizationExceeded()",
          );
        });
        it("AND WHEN doing a borrow which pushes U to 2, THEN it succeeds", async () => {
          await expect(exactlyEnv.borrowMP("DAI", secondPoolID, "12000", "20000")).to.not.be.reverted;
        });

        it("WHEN borrowing 1050 DAI THEN it succeeds", async () => {
          await exactlyEnv.borrowMP("DAI", secondPoolID, "1050");
        });
      });
      describe("GIVEN curve parameters yielding Ub=1, Umax=12, Ufull=11.99, R0=0.02, Rb=0.18", () => {
        beforeEach(async () => {
          // A = ((Umax*(Umax-Ub))/Ub)*(Rb-R0)
          // A = ((12*(12-1))/1)*(0.18-0.02)
          // A = 21.12000000000000000000

          // B = ((Umax/Ub)*R0) + (1-(Umax/Ub))*Rb
          // B = ((12/1)*0.02) + (1-(12/1))*0.18
          // B =-1.74000000000000000000

          const A = parseUnits("21.12"); // A parameter for the curve
          const B = parseUnits("-1.74"); // B parameter for the curve
          const fixedMaxUtilization = parseUnits("12"); // Maximum utilization rate
          const fixedFullUtilization = parseUnits("11.99"); // Full utilization rate
          await interestRateModel.setFixedCurveParameters(A, B, fixedMaxUtilization, fixedFullUtilization);
          exactlyEnv.switchWallet(alice);
        });
        it("WHEN doing a borrow which pushes U to the full UR, THEN it does not revert", async () => {
          await expect(exactlyEnv.borrowMP("DAI", secondPoolID, "12000", "34000")).to.not.be.reverted;
        });
        it("WHEN doing a borrow which pushes U above the full UR, THEN it reverts", async () => {
          await expect(exactlyEnv.borrowMP("DAI", secondPoolID, "12001", "34000")).to.be.revertedWith(
            "UtilizationExceeded()",
          );
        });
        describe("WHEN borrowing 11k of SP liquidity", () => {
          let tx: any;
          beforeEach(async () => {
            tx = await exactlyEnv.borrowMP("DAI", secondPoolID, "11000", "16000");
          });
          it("THEN the fee charged (300%) implies an utilization rate of 11", async () => {
            await expectFee(tx, parseUnits("2546"));
          });
        });
        describe("GIVEN a borrow of 1000 DAI in the closest maturity", () => {
          let aliceFirstBorrow: Array<BigNumber>;
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "1000");
            aliceFirstBorrow = await exactlyEnv.getMarket("DAI").fixedBorrowPositions(secondPoolID, alice.address);
          });
          describe("WHEN borrowing 1000 DAI in a following maturity", () => {
            beforeEach(async () => {
              await exactlyEnv.borrowMP("DAI", thirdPoolID, "1000");
            });
            it("THEN the rate charged is the same one as the last borrow, since the sp total supply is the same", async () => {
              const aliceNewBorrow = await exactlyEnv.getMarket("DAI").fixedBorrowPositions(thirdPoolID, alice.address);
              // the fee charged is the double since third pool id has one more week
              // we subtract 500 for rounding division
              expect(aliceFirstBorrow[1]).to.be.equal(aliceNewBorrow[1].div(2).sub(500));
            });
          });
        });
      });
    });
  });

  describe("GIVEN curve parameters with an Umax(20), Ufull(12) AND enough collateral AND SP liquidity", () => {
    beforeEach(async () => {
      // umax = 20
      // ub = 1
      // r0 = 0
      // rb = 22
      // A = ((Umax*(Umax-Ub))/Ub)*(Rb-R0)
      // A = ((20*(20-1))/1)*(22-0)
      // A = 8360.00000000000000000000

      // B = ((Umax/Ub)*R0) + (1-(Umax/Ub))*Rb
      // B = ((20/1)*0) + (1-(20/1))*22
      // B = -418.00000000000000000000

      const A = parseUnits("8360");
      const B = parseUnits("-418");
      const fixedMaxUtilization = parseUnits("20");
      const fixedFullUtilization = parseUnits("12");
      await interestRateModel.setFixedCurveParameters(A, B, fixedMaxUtilization, fixedFullUtilization);
      await exactlyEnv.depositSP("WETH", "10");
      await exactlyEnv.enterMarket("WETH");
      await exactlyEnv.depositSP("DAI", "1200");
    });
    it("WHEN borrowing more than whats available in the SP, THEN it reverts with UtilizationExceeded", async () => {
      // this'd push U to 15
      await expect(exactlyEnv.borrowMP("DAI", secondPoolID, "1500")).to.be.revertedWith("UtilizationExceeded()");
    });
  });

  describe("GIVEN curve parameters yielding Ub=0.8, Umax=1.1, R0=0.02 and Rb=0.14", () => {
    beforeEach(async () => {
      // A = ((Umax*(Umax-Ub))/Ub)*(Rb-R0)
      // A = ((1.1*(1.1-0.8))/0.8)*(0.14-0.02)
      // A = 0.04950000000000000000

      // B = ((Umax/Ub)*R0) + (1-(Umax/Ub))*Rb
      // B = ((1.1/0.8)*0.02) + (1-(1.1/0.8))*0.14
      // B = -.02500000000000000000

      const A = parseUnits("0.0495"); // A parameter for the curve
      const B = parseUnits("-0.025"); // B parameter for the curve
      const fixedMaxUtilization = parseUnits("1.1"); // Maximum utilization rate
      const fixedFullUtilization = parseUnits("1"); // Full utilization rate
      await interestRateModel.setFixedCurveParameters(A, B, fixedMaxUtilization, fixedFullUtilization);
    });
    describe("GIVEN enough collateral", () => {
      beforeEach(async () => {
        await exactlyEnv.depositSP("WETH", "10");
        await exactlyEnv.enterMarket("WETH");
      });
      it("WHEN asking to borrow without a previous MP/SP deposit THEN it reverts with INSUFFICIENT_PROTOCOL_LIQUIDITY", async () => {
        await expect(exactlyEnv.borrowMP("DAI", secondPoolID, "1")).to.be.reverted;
      });
      describe("GIVEN a 1 DAI MP deposit", () => {
        beforeEach(async () => {
          await exactlyEnv.depositMP("DAI", secondPoolID, "1");
        });
        it("WHEN borrowing 1 DAI, then it succeeds", async () => {
          await expect(exactlyEnv.borrowMP("DAI", secondPoolID, "1", "2")).to.not.be.reverted;
        });
      });
      describe("GIVEN a 1200 DAI SP deposit", () => {
        beforeEach(async () => {
          await exactlyEnv.depositSP("DAI", "1200");
        });
        it("WHEN borrowing 1 DAI, then it succeeds", async () => {
          await expect(exactlyEnv.borrowMP("DAI", secondPoolID, "1")).to.not.be.reverted;
        });
      });
      describe("small amounts", () => {
        describe("GIVEN a 10 DAI SP deposit", () => {
          beforeEach(async () => {
            await exactlyEnv.depositSP("DAI", "10");
          });
          it("WHEN trying to borrow 1 unit of a DAI, THEN it doesn't revert, even when U difference rounds down to zero", async () => {
            await expect(
              exactlyEnv.getMarket("DAI").borrowAtMaturity(secondPoolID, 1, 100, owner.address, owner.address),
            ).to.not.be.reverted;
          });
          describe("WHEN borrowing 11 wei of a DAI", () => {
            let tx: any;
            beforeEach(async () => {
              tx = exactlyEnv.getMarket("DAI").borrowAtMaturity(secondPoolID, 11, 100000, owner.address, owner.address);
              await tx;
            });
            it("THEN it doesn't revert because theres a difference in utilization rate", async () => {
              await expect(tx).to.not.be.reverted;
            });
            it("AND the fee charged is zero, since the fee rounded down to zero", async () => {
              const { fee } = (await (await tx).wait()).events.filter((it: any) => it.event === "BorrowAtMaturity")[0]
                .args;
              expect(fee).to.eq(0);
            });
          });
          describe("WHEN borrowing 10000 wei of a DAI", () => {
            let tx: any;
            beforeEach(async () => {
              tx = exactlyEnv
                .getMarket("DAI")
                .borrowAtMaturity(secondPoolID, 10000, 100000, owner.address, owner.address);
              await tx;
            });
            it("THEN the fee didn't round down to zero", async () => {
              const { fee } = (await (await tx).wait()).events.filter((it: any) => it.event === "BorrowAtMaturity")[0]
                .args;
              expect(fee).to.gt(0);
              expect(fee).to.lt(31);
            });
          });
        });
      });
    });
    describe("integration tests for contracts calling the InterestRateModel", () => {
      describe("AND GIVEN 1kDAI of SP liquidity", () => {
        beforeEach(async () => {
          await exactlyEnv.depositSP("DAI", "12000");
          await exactlyEnv.transfer("WETH", alice, "10");
          exactlyEnv.switchWallet(alice);
          await exactlyEnv.depositSP("WETH", "10");
          await exactlyEnv.enterMarket("WETH");
          await exactlyEnv.moveInTime(nextPoolID);
        });
        describe("WHEN borrowing 1DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "1");
          });
          it("THEN a yearly interest of 2% is charged over four week (0.02*28/365)", async () => {
            const borrowed = await exactlyEnv.getDebt("DAI");
            // (0.02 * 28) / 365 = 0.00153
            expect(borrowed).to.be.gt(parseUnits("1.00153"));
            expect(borrowed).to.be.lt(parseUnits("1.00154"));
          });
        });
        describe("WHEN borrowing 300 DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "300");
          });
          it("THEN a yearly interest of 2.05% (U 0->0.25) is charged over four weeks", async () => {
            const borrowed = await exactlyEnv.getDebt("DAI");
            expect(borrowed).to.be.gt(parseUnits("300.472"));
            expect(borrowed).to.be.lt(parseUnits("300.473"));
          });
        });
        describe("WHEN borrowing 900 DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "900");
          });
          it("THEN a yearly interest of 2.16% (U 0 -> 0.75) is charged over four weeks", async () => {
            const borrowed = await exactlyEnv.getDebt("DAI");
            expect(borrowed).to.be.gt(parseUnits("901.491"));
            expect(borrowed).to.be.lt(parseUnits("901.492"));
          });
        });
      });
      describe("AND GIVEN 1kDAI of SP liquidity AND 500DAI of MP liquidity", () => {
        beforeEach(async () => {
          await exactlyEnv.depositSP("DAI", "12000");
          await exactlyEnv.depositMP("DAI", secondPoolID, "500");
          await exactlyEnv.transfer("WETH", alice, "10");
          exactlyEnv.switchWallet(alice);
          await exactlyEnv.depositSP("WETH", "10");
          await exactlyEnv.enterMarket("WETH");
          await exactlyEnv.moveInTime(nextPoolID);
        });
        describe("WHEN borrowing 1050 DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "1050");
          });
          it("THEN a yearly interest of 2.18% (U 0->0.84) is charged over four weeks", async () => {
            const borrowed = await exactlyEnv.getDebt("DAI");
            expect(borrowed).to.be.gt(parseUnits("1051.756"));
            expect(borrowed).to.be.lt(parseUnits("1051.757"));
          });
        });
      });
      describe("AND GIVEN 2kDAI of SP liquidity AND 1kDAI of MP liquidity", () => {
        beforeEach(async () => {
          await exactlyEnv.depositSP("DAI", "24000");
          await exactlyEnv.depositMP("DAI", secondPoolID, "1000");
          await exactlyEnv.transfer("WETH", alice, "10");
          exactlyEnv.switchWallet(alice);
          await exactlyEnv.depositSP("WETH", "10");
          await exactlyEnv.enterMarket("WETH");
          await exactlyEnv.moveInTime(nextPoolID);
        });
        describe("WHEN borrowing 1200 DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "1200");
          });
          it("THEN a yearly interest of 2.1% (U 0->0.48) is charged over four weeks", async () => {
            const borrowed = await exactlyEnv.getDebt("DAI");
            expect(borrowed).to.be.gt(parseUnits("1201.934"));
            expect(borrowed).to.be.lt(parseUnits("1201.935"));
          });
          describe("previous borrows are accounted for when computing the utilization rate", () => {
            describe("AND WHEN another user borrows 400 more DAI", () => {
              beforeEach(async () => {
                exactlyEnv.switchWallet(owner);
                await exactlyEnv.transfer("WETH", bob, "10");
                exactlyEnv.switchWallet(bob);
                await exactlyEnv.depositSP("WETH", "10");
                await exactlyEnv.enterMarket("WETH");
                await exactlyEnv.borrowMP("DAI", secondPoolID, "400");
              });
              it("THEN a yearly interest of 2.24% (U 0.48->0.64, considering both borrows) is charged over four weeks", async () => {
                const borrowed = await exactlyEnv.getDebt("DAI");
                expect(borrowed).to.be.gt(parseUnits("400.687"));
                expect(borrowed).to.be.lt(parseUnits("400.688"));
              });
            });
          });
        });
      });
      describe("AND GIVEN 1kDAI of SP liquidity AND 2kDAI of MP liquidity", () => {
        beforeEach(async () => {
          await exactlyEnv.depositSP("DAI", "12000");
          await exactlyEnv.depositMP("DAI", secondPoolID, "2000");
          await exactlyEnv.transfer("WETH", alice, "10");
          exactlyEnv.switchWallet(alice);
          await exactlyEnv.depositSP("WETH", "10");
          await exactlyEnv.enterMarket("WETH");
          await exactlyEnv.moveInTime(nextPoolID);
        });
        describe("WHEN borrowing 1000 DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "1000");
          });
          it("THEN a yearly interest of 2.1% (U 0->0.71) is charged over four weeks", async () => {
            const borrowed = await exactlyEnv.getDebt("DAI");
            expect(borrowed).to.be.gt(parseUnits("1001.651"));
            expect(borrowed).to.be.lt(parseUnits("1001.652"));
          });
        });
      });
    });
    describe("GIVEN a token with 6 decimals instead of 18", () => {
      it("WHEN asking for the interest at 0% utilization rate THEN it returns R0=0.02", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 365 * 86_400, // force yearly calculation
          parseUnits("0.00001", 6),
          parseUnits("0", 6), // 0 previous borrows
          parseUnits("50", 6), // 50 available liquidity (mp deposits)
          parseUnits("50", 6), // 50 available liquidity (sp deposits)
        );
        expect(rate).to.gt(parseUnits("0.02"));
        expect(rate).to.lt(parseUnits("0.020001"));
      });
      it("AND WHEN asking for the interest at 80% (Ub)utilization rate THEN it returns Rb=0.14", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 365 * 86_400, // force yearly calculation
          parseUnits("0.00001", 6),
          parseUnits("80", 6), // 80 borrowed, this is what makes U=0.8
          parseUnits("50", 6), // 50 available liquidity (mp deposits)
          parseUnits("50", 6), // 50 available liquidity (sp deposits)
        );
        expect(rate).to.gt(parseUnits("0.14"));
        expect(rate).to.lt(parseUnits("0.140001"));
      });
    });

    it("WHEN asking for the interest at 0% utilization rate THEN it returns R0=0.02", async () => {
      const rate = await interestRateModel.getFixedBorrowRate(
        nextPoolID,
        nextPoolID - 365 * 86_400, // force yearly calculation
        parseUnits("0.0000000000001"),
        parseUnits("0"),
        parseUnits("50"),
        parseUnits("50"),
      );
      expect(rate).to.equal(parseUnits("0.02"));
    });
    it("AND WHEN asking for the interest at 80% (Ub)utilization rate THEN it returns Rb=0.14", async () => {
      const rate = await interestRateModel.getFixedBorrowRate(
        nextPoolID,
        nextPoolID - 365 * 86_400, // force yearly calculation
        parseUnits("0.0000001"),
        parseUnits("80"), // 80 borrowed, this is what makes U=0.8
        parseUnits("50"),
        parseUnits("50"),
      );
      expect(rate).to.equal(parseUnits("0.14"));
    });
    describe("high utilization rates", () => {
      it("AND WHEN asking for the interest at 90% (>Ub)utilization rate THEN it returns R=0.22 (price hike)", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 365 * 86_400, // force yearly calculation
          parseUnits("0.0000001"),
          parseUnits("90"), // 90 borrowed, this is what makes U=0.9
          parseUnits("50"),
          parseUnits("50"),
        );
        expect(rate).to.equal(parseUnits("0.2225"));
      });
      it("AND WHEN asking for the interest at 100% (>Ub)utilization rate THEN it returns R=0.47 (price hike)", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 365 * 86_400,
          parseUnits("0.000000001"),
          parseUnits("99.999999999"),
          parseUnits("50"),
          parseUnits("50"),
        );
        expect(rate).to.gt(parseUnits("0.469"));
        expect(rate).to.lt(parseUnits("0.47"));
      });
      it("AND WHEN asking for the interest at 105% ur (higher than Ufull) THEN it reverts", async () => {
        await expect(
          interestRateModel.getFixedBorrowRate(
            nextPoolID,
            nextPoolID - 365 * 86_400,
            parseUnits("0.0000001"),
            parseUnits("105"),
            parseUnits("50"),
            parseUnits("50"),
          ),
        ).to.be.revertedWith("UtilizationExceeded()");
      });
      it("AND WHEN asking for the interest at Umax, THEN it reverts", async () => {
        const tx = interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 365 * 86_400,
          parseUnits("0.000001"),
          parseUnits("110"),
          parseUnits("50"),
          parseUnits("50"),
        );

        await expect(tx).to.be.revertedWith("UtilizationExceeded()");
      });
      it("AND WHEN asking for the interest at U>Umax, THEN it reverts", async () => {
        const tx = interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 365 * 86_400,
          parseUnits("0.0000001"),
          parseUnits("115"),
          parseUnits("50"),
          parseUnits("50"),
        );

        await expect(tx).to.be.revertedWith("UtilizationExceeded()");
      });
    });
    describe("interest for durations other than a full year", () => {
      it("WHEN asking for the interest for negative time difference, THEN it reverts", async () => {
        const tx = interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID + 86_400,
          parseUnits("0.00000001"),
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("50"),
          parseUnits("50"),
        );

        await expect(tx).to.be.revertedWith("AlreadyMatured()");
      });
      it("WHEN asking for the interest for a time difference of zero, THEN it reverts", async () => {
        const tx = interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID,
          parseUnits("0.00000001"),
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("50"),
          parseUnits("50"),
        );

        await expect(tx).to.be.revertedWith("AlreadyMatured()");
      });
      it("WHEN asking for the interest for a 5-day period at Ub, THEN it returns Rb*(5/365)", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 5 * 86_400,
          parseUnits("0.00000001"),
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("50"),
          parseUnits("50"),
        );

        // 0.14*5/365
        expect(rate).to.gt(parseUnits(".0019178"));
        expect(rate).to.lt(parseUnits(".0019179"));
      });
      it("WHEN asking for the interest for a two-week period at Ub, THEN it returns Rb*(14/365)", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 14 * 86_400,
          parseUnits("0.00000001"),
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("50"),
          parseUnits("50"),
        );

        // 0.14*14/365
        expect(rate).to.be.gt(parseUnits(".00536986"));
        expect(rate).to.be.lt(parseUnits(".00536987"));
      });
      it("WHEN asking for the interest for a one-day period at U0, THEN it returns R0*(1/365)", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 86_400,
          parseUnits("0.00000001"),
          parseUnits("0.0000000000001"), // 0 borrowed, this is what makes U=0
          parseUnits("50"),
          parseUnits("50"),
        );

        // 0.02*1/365
        // .00005479452054794520
        expect(rate).to.be.gt(parseUnits(".0000547945"));
        expect(rate).to.be.lt(parseUnits(".0000547946"));
      });

      it("WHEN asking for the interest for a five-second period at U0, THEN it returns R0*(5/(365*24*60*60))", async () => {
        const rate = await interestRateModel.getFixedBorrowRate(
          nextPoolID,
          nextPoolID - 5,
          parseUnits("0.0000000000001"),
          parseUnits("0"),
          parseUnits("50"),
          parseUnits("50"),
        );

        // 0.02*5/(365*24*60*60)
        expect(rate).to.be.gt(parseUnits(".00000000317097"));
        expect(rate).to.be.lt(parseUnits(".00000000317098"));
      });
    });
  });

  it("WHEN calling setFixedCurveParameters function, THEN it should emit FixedCurveParametersSet", async () => {
    await expect(
      interestRateModel.setFixedCurveParameters(
        parseUnits("0.08"),
        parseUnits("-0.046"),
        parseUnits("1.2"),
        parseUnits("1"),
      ),
    )
      .to.emit(interestRateModel, "FixedCurveParametersSet")
      .withArgs(parseUnits("0.08"), parseUnits("-0.046"), parseUnits("1.2"), parseUnits("1"));
  });
  it("WHEN calling setFlexibleCurveParameters function, THEN it should emit FlexibleCurveParametersSet", async () => {
    await expect(
      interestRateModel.setFlexibleCurveParameters(
        parseUnits("0.08"),
        parseUnits("-0.046"),
        parseUnits("1.2"),
        parseUnits("1"),
      ),
    )
      .to.emit(interestRateModel, "FlexibleCurveParametersSet")
      .withArgs(parseUnits("0.08"), parseUnits("-0.046"), parseUnits("1.2"), parseUnits("1"));
  });

  it("WHEN an unauthorized user calls setFixedCurveParameters function, THEN it should revert", async () => {
    const A = parseUnits("0.092"); // A parameter for the curve
    const B = parseUnits("-0.086666666666666666"); // B parameter for the curve
    const fixedMaxUtilization = parseUnits("1.2"); // Maximum utilization rate
    const fixedFullUtilization = parseUnits("1"); // Full utilization rate
    await expect(
      interestRateModel.connect(alice).setFixedCurveParameters(A, B, fixedMaxUtilization, fixedFullUtilization),
    ).to.be.revertedWith("AccessControl");
  });
  it("WHEN an unauthorized user calls setFlexibleCurveParameters function, THEN it should revert", async () => {
    const A = parseUnits("0.092"); // A parameter for the curve
    const B = parseUnits("-0.086666666666666666"); // B parameter for the curve
    const flexibleMaxUtilization = parseUnits("1.2"); // Maximum utilization rate
    const flexibleFullUtilization = parseUnits("1"); // Full utilization rate
    await expect(
      interestRateModel
        .connect(alice)
        .setFlexibleCurveParameters(A, B, flexibleMaxUtilization, flexibleFullUtilization),
    ).to.be.revertedWith("AccessControl");
  });
});
