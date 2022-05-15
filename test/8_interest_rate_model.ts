import { expect } from "chai";
import { parseUnits } from "@ethersproject/units";
import { Contract, BigNumber } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ethers } from "hardhat";
import { ExaTime, expectFee } from "./exactlyUtils";
import { DefaultEnv } from "./defaultEnv";

describe("InterestRateModel", () => {
  let exactlyEnv: DefaultEnv;
  const exaTime = new ExaTime();
  const nextPoolID = exaTime.poolIDByNumberOfWeek(1);
  const secondPoolID = exaTime.poolIDByNumberOfWeek(2);
  const thirdPoolID = exaTime.poolIDByNumberOfWeek(3);

  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;
  let interestRateModel: Contract;
  let snapshot: any;

  beforeEach(async () => {
    exactlyEnv = await DefaultEnv.create({
      useRealInterestRateModel: true,
    });
    [owner, alice, bob] = await ethers.getSigners();

    interestRateModel = exactlyEnv.interestRateModel;
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await exactlyEnv.takeSnapshot();
  });

  afterEach(async () => {
    await exactlyEnv.revertSnapshot(snapshot);
  });

  describe("setting different curve parameters", () => {
    it("WHEN deploying a contract with A and B parameters yielding an invalid curve THEN it reverts", async () => {
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
      const maxUtilization = parseUnits("1.2"); // Maximum utilization rate
      const fullUtilization = parseUnits("1"); // Full utilization rate
      const InterestRateModelFactory = await ethers.getContractFactory("InterestRateModel", {});
      const tx = InterestRateModelFactory.deploy(
        A, // A parameter for the curve
        B, // B parameter for the curve
        maxUtilization, // High UR slope rate
        fullUtilization, // Full UR
        0,
      );
      await expect(tx).to.be.reverted;
    });
    it("WHEN setting A and B parameters yielding an invalid curve THEN it reverts", async () => {
      // same as case above
      const A = parseUnits("0.092"); // A parameter for the curve
      const B = parseUnits("-0.086666666666666666"); // B parameter for the curve
      const maxUtilization = parseUnits("1.2"); // Maximum utilization rate
      const fullUtilization = parseUnits("1"); // Full utilization rate
      const tx = interestRateModel.setCurveParameters(A, B, maxUtilization, fullUtilization);

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
      const maxUtilization = parseUnits("1.2"); // Maximum utilization rate
      const fullUtilization = parseUnits("1"); // Full utilization rate

      beforeEach(async () => {
        await interestRateModel.setCurveParameters(A, B, maxUtilization, fullUtilization);
      });
      it("THEN the new maxUtilization is readable", async () => {
        expect(await interestRateModel.maxUtilization()).to.be.equal(maxUtilization);
      });
      it("AND the curves R0 stayed the same", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("0.00000000000001"),
          parseUnits("0"),
          parseUnits("50"),
          parseUnits("50"),
        );
        expect(rate).to.gt(parseUnits("0.019"));
        expect(rate).to.lt(parseUnits("0.021"));
      });
      it("AND the curves Rb and Ub changed accordingly", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("0.00000000000001"),
          parseUnits("90"),
          parseUnits("50"),
          parseUnits("50"),
        );
        expect(rate).to.gt(parseUnits("0.21"));
        expect(rate).to.lt(parseUnits("0.23"));
      });
      it("AND the curves Umax changed", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
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
      const maxUtilization = parseUnits("1.1"); // Maximum utilization rate
      const fullUtilization = parseUnits("1"); // Full utilization rate

      beforeEach(async () => {
        await interestRateModel.setCurveParameters(A, B, maxUtilization, fullUtilization);
      });
      it("THEN the new parameters are readable", async () => {
        expect(await interestRateModel.curveParameterA()).to.be.equal(A);
        expect(await interestRateModel.curveParameterB()).to.be.equal(B);
        expect(await interestRateModel.maxUtilization()).to.be.equal(maxUtilization);
      });
      it("AND the curves R0 changed accordingly", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("0.000000000001"),
          parseUnits("0"),
          parseUnits("50"),
          parseUnits("50"),
        );
        expect(rate).to.gt(parseUnits("0.049"));
        expect(rate).to.lt(parseUnits("0.051"));
      });
      it("AND the curves Rb stays the same", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
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
        await exactlyEnv.enterMarkets(["WETH"]);
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
          const maxUtilization = parseUnits("3"); // Maximum utilization rate
          const fullUtilization = parseUnits("2"); // Full utilization rate
          await interestRateModel.setCurveParameters(A, B, maxUtilization, fullUtilization);
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
          const maxUtilization = parseUnits("12"); // Maximum utilization rate
          const fullUtilization = parseUnits("11.99"); // Full utilization rate
          await interestRateModel.setCurveParameters(A, B, maxUtilization, fullUtilization);
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
            await expectFee(tx, parseUnits("636"));
          });
        });
        describe("GIVEN a borrow of 1000 DAI in the closest maturity", () => {
          let aliceFirstBorrow: Array<BigNumber>;
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "1000");
            aliceFirstBorrow = await exactlyEnv.getFixedLender("DAI").mpUserBorrowedAmount(secondPoolID, alice.address);
          });
          describe("WHEN borrowing 1000 DAI in a following maturity", () => {
            beforeEach(async () => {
              await exactlyEnv.borrowMP("DAI", thirdPoolID, "1000");
            });
            it("THEN the rate charged is the same one as the last borrow, since the sp total supply is the same", async () => {
              const aliceNewBorrow = await exactlyEnv
                .getFixedLender("DAI")
                .mpUserBorrowedAmount(thirdPoolID, alice.address);
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
      const maxUtilization = parseUnits("20");
      const fullUtilization = parseUnits("12");
      await interestRateModel.setCurveParameters(A, B, maxUtilization, fullUtilization);
      await exactlyEnv.depositSP("WETH", "10");
      await exactlyEnv.enterMarkets(["WETH"]);
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
      const maxUtilization = parseUnits("1.1"); // Maximum utilization rate
      const fullUtilization = parseUnits("1"); // Full utilization rate
      await interestRateModel.setCurveParameters(A, B, maxUtilization, fullUtilization);
    });
    describe("GIVEN enough collateral", () => {
      beforeEach(async () => {
        await exactlyEnv.depositSP("WETH", "10");
        await exactlyEnv.enterMarkets(["WETH"]);
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
              exactlyEnv.getFixedLender("DAI").borrowAtMaturity(secondPoolID, 1, 100, owner.address, owner.address),
            ).to.not.be.reverted;
          });
          describe("WHEN borrowing 11 wei of a DAI", () => {
            let tx: any;
            beforeEach(async () => {
              tx = exactlyEnv
                .getFixedLender("DAI")
                .borrowAtMaturity(secondPoolID, 11, 100000, owner.address, owner.address);
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
                .getFixedLender("DAI")
                .borrowAtMaturity(secondPoolID, 10000, 100000, owner.address, owner.address);
              await tx;
            });
            it("THEN the fee didnt round down to zero", async () => {
              const { fee } = (await (await tx).wait()).events.filter((it: any) => it.event === "BorrowAtMaturity")[0]
                .args;
              expect(fee).to.gt(0);
              expect(fee).to.lt(10);
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
          await exactlyEnv.enterMarkets(["WETH"]);
          await exactlyEnv.moveInTime(nextPoolID);
        });
        describe("WHEN borrowing 1DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "1");
          });
          it("THEN a yearly interest of 2% is charged over a week (0.02*7/365)", async () => {
            const [, borrowed] = await exactlyEnv.accountSnapshot("DAI", secondPoolID);
            // (0.02 * 7) / 365 = 0.00384
            expect(borrowed).to.be.gt(parseUnits("1.000383"));
            expect(borrowed).to.be.lt(parseUnits("1.000385"));
          });
        });
        describe("WHEN borrowing 300 DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "300");
          });
          it("THEN a yearly interest of 2.05% (U 0->0.25) is charged over a week", async () => {
            const [, borrowed] = await exactlyEnv.accountSnapshot("DAI", secondPoolID);

            expect(borrowed).to.be.gt(parseUnits("300.118"));
            expect(borrowed).to.be.lt(parseUnits("300.119"));
          });
        });
        describe("WHEN borrowing 900 DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "900");
          });
          it("THEN a yearly interest of 2.16% (U 0 -> 0.75) is charged over a week", async () => {
            const [, borrowed] = await exactlyEnv.accountSnapshot("DAI", secondPoolID);

            expect(borrowed).to.be.gt(parseUnits("900.372"));
            expect(borrowed).to.be.lt(parseUnits("900.373"));
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
          await exactlyEnv.enterMarkets(["WETH"]);
          await exactlyEnv.moveInTime(nextPoolID);
        });
        describe("WHEN borrowing 1050 DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "1050");
          });
          it("THEN a yearly interest of 2.18% (U 0->0.84) is charged over a week", async () => {
            const [, borrowed] = await exactlyEnv.accountSnapshot("DAI", secondPoolID);

            expect(borrowed).to.be.gt(parseUnits("1050.439"));
            expect(borrowed).to.be.lt(parseUnits("1050.440"));
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
          await exactlyEnv.enterMarkets(["WETH"]);
          await exactlyEnv.moveInTime(nextPoolID);
        });
        describe("WHEN borrowing 1200 DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "1200");
          });
          it("THEN a yearly interest of 2.1% (U 0->0.48) is charged over a week", async () => {
            const [, borrowed] = await exactlyEnv.accountSnapshot("DAI", secondPoolID);

            expect(borrowed).to.be.gt(parseUnits("1200.483"));
            expect(borrowed).to.be.lt(parseUnits("1200.484"));
          });
          describe("previous borrows are accounted for when computing the utilization rate", () => {
            describe("AND WHEN another user borrows 400 more DAI", () => {
              beforeEach(async () => {
                exactlyEnv.switchWallet(owner);
                await exactlyEnv.transfer("WETH", bob, "10");
                exactlyEnv.switchWallet(bob);
                await exactlyEnv.depositSP("WETH", "10");
                await exactlyEnv.enterMarkets(["WETH"]);
                await exactlyEnv.borrowMP("DAI", secondPoolID, "400");
              });
              it("THEN a yearly interest of 2.24% (U 0.48->0.64, considering both borrows) is charged over a week", async () => {
                const [, borrowed] = await exactlyEnv.accountSnapshot("DAI", secondPoolID);

                expect(borrowed).to.be.gt(parseUnits("400.171"));
                expect(borrowed).to.be.lt(parseUnits("400.172"));
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
          await exactlyEnv.enterMarkets(["WETH"]);
          await exactlyEnv.moveInTime(nextPoolID);
        });
        describe("WHEN borrowing 1000 DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "1000");
          });
          it("THEN a yearly interest of 2.1% (U 0->0.71) is charged over a week", async () => {
            const [, borrowed] = await exactlyEnv.accountSnapshot("DAI", secondPoolID);

            expect(borrowed).to.be.gt(parseUnits("1000.412"));
            expect(borrowed).to.be.lt(parseUnits("1000.413"));
          });
        });
      });
    });
    describe("GIVEN a token with 6 decimals instead of 18", () => {
      it("WHEN asking for the interest at 0% utilization rate THEN it returns R0=0.02", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("0.00001", 6),
          parseUnits("0", 6), // 0 previous borrows
          parseUnits("50", 6), // 50 available liquidity (mp deposits)
          parseUnits("50", 6), // 50 available liquidity (sp deposits)
        );
        expect(rate).to.gt(parseUnits("0.02"));
        expect(rate).to.lt(parseUnits("0.020001"));
      });
      it("AND WHEN asking for the interest at 80% (Ub)utilization rate THEN it returns Rb=0.14", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
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
      const rate = await interestRateModel.getRateToBorrow(
        nextPoolID,
        nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
        parseUnits("0.0000000000001"),
        parseUnits("0"),
        parseUnits("50"),
        parseUnits("50"),
      );
      expect(rate).to.equal(parseUnits("0.02"));
    });
    it("AND WHEN asking for the interest at 80% (Ub)utilization rate THEN it returns Rb=0.14", async () => {
      const rate = await interestRateModel.getRateToBorrow(
        nextPoolID,
        nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
        parseUnits("0.0000001"),
        parseUnits("80"), // 80 borrowed, this is what makes U=0.8
        parseUnits("50"),
        parseUnits("50"),
      );
      expect(rate).to.equal(parseUnits("0.14"));
    });
    describe("high utilization rates", () => {
      it("AND WHEN asking for the interest at 90% (>Ub)utilization rate THEN it returns R=0.22 (price hike)", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("0.0000001"),
          parseUnits("90"), // 90 borrowed, this is what makes U=0.9
          parseUnits("50"),
          parseUnits("50"),
        );
        expect(rate).to.equal(parseUnits("0.2225"));
      });
      it("AND WHEN asking for the interest at 100% (>Ub)utilization rate THEN it returns R=0.47 (price hike)", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY,
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
          interestRateModel.getRateToBorrow(
            nextPoolID,
            nextPoolID - 365 * exaTime.ONE_DAY,
            parseUnits("0.0000001"),
            parseUnits("105"),
            parseUnits("50"),
            parseUnits("50"),
          ),
        ).to.be.revertedWith("UtilizationExceeded()");
      });
      it("AND WHEN asking for the interest at Umax, THEN it reverts", async () => {
        const tx = interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY,
          parseUnits("0.000001"),
          parseUnits("110"),
          parseUnits("50"),
          parseUnits("50"),
        );

        await expect(tx).to.be.revertedWith("UtilizationExceeded()");
      });
      it("AND WHEN asking for the interest at U>Umax, THEN it reverts", async () => {
        const tx = interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY,
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
        const tx = interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID + exaTime.ONE_DAY,
          parseUnits("0.00000001"),
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("50"),
          parseUnits("50"),
        );

        await expect(tx).to.be.revertedWith("AlreadyMatured()");
      });
      it("WHEN asking for the interest for a time difference of zero, THEN it reverts", async () => {
        const tx = interestRateModel.getRateToBorrow(
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
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 5 * exaTime.ONE_DAY,
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
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 14 * exaTime.ONE_DAY,
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
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - exaTime.ONE_DAY,
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
        const rate = await interestRateModel.getRateToBorrow(
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

  describe("getYieldForDeposit without a spFeeRate (0%)", () => {
    it("WHEN suppliedSP is 100, unassignedEarnings are 100, and amount deposited is 100, THEN earningsShare is 100 (0 for the SP)", async () => {
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("100"),
        parseUnits("100"),
        parseUnits("100"),
      );

      expect(result[0]).to.equal(parseUnits("100"));
      expect(result[1]).to.equal(parseUnits("0"));
    });

    it("WHEN suppliedSP is 101, unassignedEarnings are 100, and amount deposited is 100, THEN earningsShare is 99.0099... (0 for the SP)", async () => {
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("101"),
        parseUnits("100"),
        parseUnits("100"),
      );

      expect(result[0]).to.closeTo(parseUnits("99.00990099"), parseUnits("00.00000001").toNumber());
      expect(result[1]).to.eq(parseUnits("0"));
    });

    it("WHEN suppliedSP is 200, unassignedEarnings are 100, and amount deposited is 100, THEN earningsShare is 50 (0 for the SP)", async () => {
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("200"),
        parseUnits("100"),
        parseUnits("100"),
      );

      expect(result[0]).to.equal(parseUnits("50"));
      expect(result[1]).to.equal(parseUnits("0"));
    });

    it("WHEN suppliedSP is 0, unassignedEarnings are 100, and amount deposited is 100, THEN earningsShare is 0 (0 for the SP)", async () => {
      const result = await interestRateModel.getYieldForDeposit(parseUnits("0"), parseUnits("100"), parseUnits("100"));

      expect(result[0]).to.equal(parseUnits("0"));
      expect(result[1]).to.equal(parseUnits("0"));
    });

    it("WHEN suppliedSP is 100, unassignedEarnings are 0, and amount deposited is 100, THEN earningsShare is 0 (0 for the SP)", async () => {
      const result = await interestRateModel.getYieldForDeposit(parseUnits("100"), parseUnits("0"), parseUnits("100"));

      expect(result[0]).to.equal(parseUnits("0"));
      expect(result[1]).to.equal(parseUnits("0"));
    });

    it("WHEN suppliedSP is 100, unassignedEarnings are 100, and amount deposited is 0, THEN earningsShare is 0 (0 for the SP)", async () => {
      const result = await interestRateModel.getYieldForDeposit(parseUnits("100"), parseUnits("100"), parseUnits("0"));

      expect(result[0]).to.equal(parseUnits("0"));
      expect(result[1]).to.equal(parseUnits("0"));
    });
  });

  describe("getYieldForDeposit with a custom spFeeRate, suppliedSP of 100, unassignedEarnings of 100 and amount deposited of 100", () => {
    it("WHEN spFeeRate is 20%, THEN earningsShare is 80 (20 for the SP)", async () => {
      await interestRateModel.setSPFeeRate(parseUnits("0.2"));
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("100"),
        parseUnits("100"),
        parseUnits("100"),
      );

      expect(result[0]).to.eq(parseUnits("80"));
      expect(result[1]).to.eq(parseUnits("20"));
    });

    it("WHEN spFeeRate is 20% AND suppliedSP is 101 THEN earningsShare is 79.2079... (19.8019... for the SP)", async () => {
      await interestRateModel.setSPFeeRate(parseUnits("0.2"));
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("101"),
        parseUnits("100"),
        parseUnits("100"),
      );

      expect(result[0]).to.closeTo(parseUnits("79.20792079"), parseUnits("00.00000001").toNumber());
      expect(result[1]).to.closeTo(parseUnits("19.80198019"), parseUnits("00.00000001").toNumber());
    });
  });

  it("WHEN calling setSPFeeRate function, THEN it should update spFeeRate", async () => {
    await interestRateModel.setSPFeeRate(parseUnits("0.2"));
    expect(await interestRateModel.spFeeRate()).to.eq(parseUnits("0.2"));
  });
  it("WHEN calling setSPFeeRate function, THEN it should emit SpFeeRateUpdated", async () => {
    await expect(interestRateModel.setSPFeeRate(parseUnits("0.2")))
      .to.emit(interestRateModel, "SpFeeRateUpdated")
      .withArgs(parseUnits("0.2"));
  });
  it("WHEN calling setCurveParameters function, THEN it should emit CurveParametersUpdated", async () => {
    await expect(
      interestRateModel.setCurveParameters(
        parseUnits("0.08"),
        parseUnits("-0.046"),
        parseUnits("1.2"),
        parseUnits("1"),
      ),
    )
      .to.emit(interestRateModel, "CurveParametersUpdated")
      .withArgs(parseUnits("0.08"), parseUnits("-0.046"), parseUnits("1.2"), parseUnits("1"));
  });

  it("WHEN an unauthorized user calls setSPFeeRate function, THEN it should revert", async () => {
    await expect(interestRateModel.connect(alice).setSPFeeRate(parseUnits("0"))).to.be.revertedWith("AccessControl");
  });

  it("WHEN an unauthorized user calls setCurveParameters function, THEN it should revert", async () => {
    const A = parseUnits("0.092"); // A parameter for the curve
    const B = parseUnits("-0.086666666666666666"); // B parameter for the curve
    const maxUtilization = parseUnits("1.2"); // Maximum utilization rate
    const fullUtilization = parseUnits("1"); // Full utilization rate
    await expect(
      interestRateModel.connect(alice).setCurveParameters(A, B, maxUtilization, fullUtilization),
    ).to.be.revertedWith("AccessControl");
  });
});
