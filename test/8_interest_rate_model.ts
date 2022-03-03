import { expect } from "chai";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ethers } from "hardhat";
import {
  ExaTime,
  ProtocolError,
  errorGeneric,
  expectFee,
} from "./exactlyUtils";
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
      const maxUtilizationRate = parseUnits("1.2"); // Maximum utilization rate
      const penaltyRate = parseUnits("0.0000002314814815"); // Penalty rate, not used
      const InterestRateModelFactory = await ethers.getContractFactory(
        "InterestRateModel",
        {}
      );
      const tx = InterestRateModelFactory.deploy(
        A, // A parameter for the curve
        B, // B parameter for the curve
        maxUtilizationRate, // High UR slope rate
        penaltyRate // Penalty Rate
      );
      await expect(tx).to.be.reverted;
    });
    it("WHEN setting A and B parameters yielding an invalid curve THEN it reverts", async () => {
      // same as case above
      const A = parseUnits("0.092"); // A parameter for the curve
      const B = parseUnits("-0.086666666666666666"); // B parameter for the curve
      const maxUtilizationRate = parseUnits("1.2"); // Maximum utilization rate
      const tx = interestRateModel.setCurveParameters(A, B, maxUtilizationRate);

      await expect(tx).to.be.reverted;
    });
    describe("WHEN changing the penaltyRate", () => {
      const penaltyRate = parseUnits("0.0000002314814815"); // Penalty rate
      beforeEach(async () => {
        await interestRateModel.setPenaltyRate(penaltyRate);
      });
      it("THEN the new value is readable", async () => {
        expect(await interestRateModel.penaltyRate()).to.be.equal(penaltyRate);
      });
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
      const maxUtilizationRate = parseUnits("1.2"); // Maximum utilization rate

      beforeEach(async () => {
        await interestRateModel.setCurveParameters(A, B, maxUtilizationRate);
      });
      it("THEN the new maxUtilizationRate is readable", async () => {
        expect(await interestRateModel.maxUtilizationRate()).to.be.equal(
          maxUtilizationRate
        );
      });
      it("AND the curves R0 stayed the same", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("0"),
          parseUnits("0"),
          parseUnits("100")
        );
        expect(rate).to.eq(parseUnits("0.02"));
      });
      it("AND the curves Rb and Ub changed accordingly", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("90"),
          parseUnits("0"),
          parseUnits("100")
        );
        expect(rate).to.eq(parseUnits("0.22"));
      });
      it("AND the curves Umax changed", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("110"), // 1.1 was previously an invalid UR
          parseUnits("50"),
          parseUnits("50")
        );
        expect(rate).to.eq(parseUnits("0.753333333333333334"));
      });
    });

    describe("WHEN changing the curve parameters to another valid curve with a higher R0 of 0.05", () => {
      const A = parseUnits("0.037125"); // A parameter for the curve
      const B = parseUnits("0.01625"); // B parameter for the curve
      const maxUtilizationRate = parseUnits("1.1"); // Maximum utilization rate

      beforeEach(async () => {
        await interestRateModel.setCurveParameters(A, B, maxUtilizationRate);
      });
      it("THEN the new parameters are readable", async () => {
        expect(await interestRateModel.curveParameterA()).to.be.equal(A);
        expect(await interestRateModel.curveParameterB()).to.be.equal(B);
        expect(await interestRateModel.maxUtilizationRate()).to.be.equal(
          maxUtilizationRate
        );
      });
      it("AND the curves R0 changed accordingly", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("0"),
          parseUnits("0"),
          parseUnits("100")
        );
        expect(rate).to.eq(parseUnits("0.05"));
      });
      it("AND the curves Rb stays the same", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("80"),
          parseUnits("0"),
          parseUnits("100")
        );
        expect(rate).to.eq(parseUnits("0.14"));
      });
    });
  });

  describe("dynamic use of SP liquidity", () => {
    describe("GIVEN 12k of SP liquidity AND 12 maturities AND enough collateral", () => {
      beforeEach(async () => {
        await exactlyEnv.depositSP("DAI", "12000");
        await exactlyEnv.transfer("WETH", alice, "10");
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.depositSP("WETH", "10");
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
          const maxUtilizationRate = parseUnits("3"); // Maximum utilization rate
          await interestRateModel.setCurveParameters(A, B, maxUtilizationRate);
          exactlyEnv.switchWallet(alice);
        });
        it("WHEN doing a borrow which pushes U to 3.2, THEN it reverts because the utilization rate is too high", async () => {
          await expect(
            exactlyEnv.borrowMP("DAI", secondPoolID, "3200", "4000")
          ).to.be.revertedWith(
            errorGeneric(ProtocolError.EXCEEDED_MAX_UTILIZATION_RATE)
          );
        });
        it("WHEN doing a borrow which pushes U to 6, THEN it reverts because the utilization rate is too high", async () => {
          await expect(
            exactlyEnv.borrowMP("DAI", secondPoolID, "6000", "10000")
          ).to.be.revertedWith(
            errorGeneric(ProtocolError.EXCEEDED_MAX_UTILIZATION_RATE)
          );
        });
        it("WHEN doing a borrow which pushes U to 15 (>nMaturities), THEN it reverts because there isnt enough liquidity", async () => {
          await expect(
            exactlyEnv.borrowMP("DAI", secondPoolID, "15000", "100000")
          ).to.be.revertedWith("InsufficientProtocolLiquidity()");
        });
        it("AND WHEN doing a borrow which pushes U to 2.9, THEN it succeeds", async () => {
          await expect(exactlyEnv.borrowMP("DAI", secondPoolID, "2900", "4000"))
            .to.not.be.reverted;
        });

        it("WHEN borrowing 1050 DAI THEN it succeds", async () => {
          await exactlyEnv.borrowMP("DAI", secondPoolID, "1050");
        });
      });
      describe("GIVEN curve parameters yiending Ub=1, Umax=12 (==nMaturities), R0=0.02, Rb=0.18", () => {
        beforeEach(async () => {
          // A = ((Umax*(Umax-Ub))/Ub)*(Rb-R0)
          // A = ((12*(12-1))/1)*(0.18-0.02)
          // A = 21.12000000000000000000

          // B = ((Umax/Ub)*R0) + (1-(Umax/Ub))*Rb
          // B = ((12/1)*0.02) + (1-(12/1))*0.18
          // B =-1.74000000000000000000

          const A = parseUnits("21.12"); // A parameter for the curve
          const B = parseUnits("-1.74"); // B parameter for the curve
          const maxUtilizationRate = parseUnits("12"); // Maximum utilization rate
          await interestRateModel.setCurveParameters(A, B, maxUtilizationRate);
          exactlyEnv.switchWallet(alice);
        });
        it("WHEN doing a borrow which pushes U to 12, THEN it reverts because the utilization rate is too high", async () => {
          await expect(
            exactlyEnv.borrowMP("DAI", secondPoolID, "12000")
          ).to.be.revertedWith(
            errorGeneric(ProtocolError.EXCEEDED_MAX_UTILIZATION_RATE)
          );
        });
        describe("WHEN borrowing 11k of SP liquidity", () => {
          let tx: any;
          beforeEach(async () => {
            tx = await exactlyEnv.borrowMP(
              "DAI",
              secondPoolID,
              "11000",
              "16000"
            );
          });
          // r = (21.12/(12-(11000/(12000/12)))) - 1.74
          // 19.38
          it("THEN the fee charged (193800%) implies an utilization rate of 11 ", async () => {
            // 11000* (19.38 * 7) / 365
            // 4088.38356164383561643835
            await expectFee(tx, parseUnits("4080"));
          });
        });
        describe("GIVEN a borrow of 2000 DAI in the closest maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "2000");
          });
          describe("WHEN borrowing 1000 DAI in a following maturity", () => {
            let tx: any;
            beforeEach(async () => {
              tx = await exactlyEnv.borrowMP("DAI", thirdPoolID, "1000");
            });
            // 10k should be available, since 2k were already lent out
            // (21.12/(12-(1000/(10000/12)))) - 1.74
            // .21555555555555555555
            it("THEN the fee charged (21.5%) implies U > 1, since the available liquidity is less", async () => {
              // 1000* (.21555555555555555555 * 14) / 365
              await expectFee(tx, parseUnits("8.267"));
            });
          });
        });
      });
    });
  });

  describe("GIVEN an interest rate model harness with parameters yielding Ub=1, Umax=3, R0=0.02 and Rb=0.14", () => {
    let IRMHarness: Contract;
    beforeEach(async () => {
      const IRMHarnessFactory = await ethers.getContractFactory(
        "InterestRateModelHarness"
      );
      // A = ((Umax*(Umax-Ub))/Ub)*(Rb-R0)
      // A = ((3*(3-1))/1)*(0.14-0.02)
      // A = .72000000000000000000

      // B = ((Umax/Ub)*R0) + (1-(Umax/Ub))*Rb
      // B = ((3/1)*0.02) + (1-(3/1))*0.14
      // B = -.22000000000000000000

      const A = parseUnits("0.72"); // A parameter for the curve
      const B = parseUnits("-0.22"); // B parameter for the curve
      const maxUtilizationRate = parseUnits("3"); // Maximum utilization rate
      const penaltyRate = parseUnits("0.025"); // Penalty rate
      const spFee = parseUnits("0"); // not important for this tests
      IRMHarness = await IRMHarnessFactory.deploy(
        A,
        B,
        maxUtilizationRate,
        penaltyRate,
        spFee,
      );
      exactlyEnv.switchWallet(alice);
    });

    describe("getRateToBorrow clear box testing", () => {
      it("WHEN asking R(0), THEN R0 is returned", async () => {
        expect(await IRMHarness.internalGetRateToBorrow(parseUnits("0"))).to.eq(
          parseUnits("0.02")
        );
      });

      it("WHEN asking R(Ub), THEN Rb is returned", async () => {
        expect(await IRMHarness.internalGetRateToBorrow(parseUnits("1"))).to.eq(
          parseUnits("0.14")
        );
      });
      // 0.72/(3-2.7)-0.22 = 2.18000000000000000000
      it("WHEN asking R(2.7), THEN 2.18 is returned", async () => {
        expect(
          await IRMHarness.internalGetRateToBorrow(parseUnits("2.7"))
        ).to.eq(parseUnits("2.18"));
      });
      // 0.72/(3-0.7)-0.22 = .09304347826086956521
      it("WHEN asking R(0.7), THEN 0.93 is returned", async () => {
        expect(
          await IRMHarness.internalGetRateToBorrow(parseUnits("0.7"))
        ).to.eq(parseUnits(".093043478260869565"));
      });
    });

    describe("trapezoid integrator clear box testing", () => {
      [
        ["0", "0.1", "0.024094095130296869"],
        ["0", "0.2", "0.028386666549483"],
        ["0", "0.4", "0.037636731085006946"],
        ["0", "0.8", "0.059425574425574425"],
        ["0", "1.5", "0.114571428571428571"],
        ["0", "2", "0.182"],
        ["0", "2.6", "0.388906669050598962"],
        ["1", "1.1", "0.149321847373146506"],
        ["1", "2", "0.281857142857142857"],
        ["1", "2.3", "0.369977204569487059"],
        ["2", "2.5", "0.783714285714285714"],
      ].forEach(([ut, ut1, expected]) => {
        it(`WHEN asking the trapezoid integrator for the rate from U=${ut} to U=${ut1}, THEN ${expected} is returned`, async () => {
          expect(
            await IRMHarness.internalTrapezoidIntegrator(
              parseUnits(ut),
              parseUnits(ut1)
            )
          ).to.eq(parseUnits(expected));
        });
      });
    });

    describe("midpoint integrator clear box testing", () => {
      [
        ["0", "0.1", "0.024089710547967666"],
        ["0", "0.2", "0.028368173030599755"],
        ["0", "0.4", "0.037553917645816724"],
        ["0", "0.8", "0.058996501749125437"],
        ["0", "1.5", "0.111785547785547785"],
        ["0", "2", "0.172311688311688311"],
        ["0", "2.6", "0.315363561493113539"],
        ["1", "1.1", "0.149306655824054134"],
        ["1", "2", "0.277678321678321678"],
        ["1", "2.3", "0.3572420476786134"],
        ["2", "2.5", "0.775356643356643356"],
      ].forEach(([ut, ut1, expected]) => {
        it(`WHEN asking the midpoint integrator for the rate from U=${ut} to U=${ut1}, THEN ${expected} is returned`, async () => {
          expect(
            await IRMHarness.internalMidpointIntegrator(
              parseUnits(ut),
              parseUnits(ut1)
            )
          ).to.eq(parseUnits(expected));
        });
      });
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
      const maxUtilizationRate = parseUnits("1.1"); // Maximum utilization rate
      await interestRateModel.setCurveParameters(A, B, maxUtilizationRate);
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
            const [, borrowed] = await exactlyEnv.accountSnapshot(
              "DAI",
              secondPoolID
            );
            // (0.02 * 7) / 365 = 0.00384
            expect(borrowed).to.be.gt(parseUnits("1.000383"));
            expect(borrowed).to.be.lt(parseUnits("1.000385"));
          });
        });
        describe("WHEN borrowing 300 DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "300");
          });
          it("THEN a yearly interest of 3.6% (U=0.3) is charged over a week (0.03*7/365)", async () => {
            const [, borrowed] = await exactlyEnv.accountSnapshot(
              "DAI",
              secondPoolID
            );

            // 0.0495/(1.1-(300/1000))-0.025 =  .03687500000000000000
            // (300*0.036875 * 7) / 365 .21215753424657534246
            expect(borrowed).to.be.gt(parseUnits("300.212"));
            expect(borrowed).to.be.lt(parseUnits("300.214"));
          });
        });
        describe("WHEN borrowing 900 DAI in the following maturity", () => {
          beforeEach(async () => {
            await exactlyEnv.borrowMP("DAI", secondPoolID, "900");
          });
          it("THEN a yearly interest of 22% (U=0.9) is charged over a week (0.2225*7/365)", async () => {
            const [, borrowed] = await exactlyEnv.accountSnapshot(
              "DAI",
              secondPoolID
            );

            // 0.0495/(1.1-(900/1000))-0.025 =.22250000000000000000
            // (900*0.2225 * 7) / 365 = 3.84041095890410958904
            expect(borrowed).to.be.gt(parseUnits("903.84"));
            expect(borrowed).to.be.lt(parseUnits("903.85"));
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
          it("THEN a yearly interest of 9.875% (U=0.7) is charged over a week", async () => {
            const [, borrowed] = await exactlyEnv.accountSnapshot(
              "DAI",
              secondPoolID
            );

            // 0.0495/(1.1-(1050/1500))-0.025 = .09875000000000000000
            // (1050*0.9875 * 7) / 365 = 19.88527397260273972602
            expect(borrowed).to.be.gt(parseUnits("1051.9"));
            expect(borrowed).to.be.lt(parseUnits("1052"));
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
          it("THEN a yearly interest of 4.5% (U=0.4) is charged over a week", async () => {
            const [, borrowed] = await exactlyEnv.accountSnapshot(
              "DAI",
              secondPoolID
            );

            // U:  0.4
            // rate:  0.045714285714285714
            // fee:  1.0520547945205478
            expect(borrowed).to.be.gt(parseUnits("1201.05"));
            expect(borrowed).to.be.lt(parseUnits("1201.06"));
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
              it("THEN a yearly interest of 6.2% (U=0.53, considering both borrows) is charged over a week", async () => {
                const [, borrowed] = await exactlyEnv.accountSnapshot(
                  "DAI",
                  secondPoolID
                );

                // U:  0.5363128491620113
                // rate:  0.06281466798810703
                // fee:  0.4818659462101361
                expect(borrowed).to.be.gt(parseUnits("400.48"));
                expect(borrowed).to.be.lt(parseUnits("400.49"));
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
          it("THEN a yearly interest of 3.9% (U=0.333) is charged over a week", async () => {
            const [, borrowed] = await exactlyEnv.accountSnapshot(
              "DAI",
              secondPoolID
            );

            // U:  0.3333333333333333
            // rate:  0.03956521739130433
            // fee:  0.7587849910661105
            expect(borrowed).to.be.gt(parseUnits("1000.75"));
            expect(borrowed).to.be.lt(parseUnits("1000.76"));
          });
        });
      });
    });
    describe("GIVEN a token with 6 decimals instead of 18", () => {
      it("WHEN asking for the interest at 0% utilization rate THEN it returns R0=0.02", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("0", 6), // 0 borrows, this is what makes U=0
          parseUnits("0", 6), // no MP supply
          parseUnits("100", 6) // 100 available from SP
        );
        expect(rate).to.eq(parseUnits("0.02"));
      });
      it("AND WHEN asking for the interest at 80% (Ub)utilization rate THEN it returns Rb=0.14", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("80", 6), // 80 borrowed, this is what makes U=0.8
          parseUnits("0"), // no MP supply
          parseUnits("100", 6) // 100 available from SP
        );
        expect(rate).to.eq(parseUnits("0.14"));
      });
    });
    describe("distinctions on where the liquidity comes from", () => {
      it("WHEN asking for the interest with a liquidity of zero THEN it reverts", async () => {
        const tx = interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - exaTime.ONE_DAY,
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("0"), // no MP supply
          parseUnits("0") // nothing available from SP
        );

        await expect(tx).to.be.reverted;
      });
      it("WHEN asking for the interest with 80 tokens borrowed and 100 supplied to the MP, THEN it returns Rb=0.14 because U=Ub", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("100"), // 100 supplied to MP
          parseUnits("0") // nothing available from SP
        );
        expect(rate).to.eq(parseUnits("0.14"));
      });
      it("WHEN asking for the interest with 80 tokens borrowed and 40 supplied to the MP AND 60 available from the SP, THEN it returns Rb=0.14 because U=Ub", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("40"), // 40 supplied to MP
          parseUnits("60") // 60 available from SP
        );
        expect(rate).to.eq(parseUnits("0.14"));
      });
      it("WHEN asking for the interest with 80 tokens borrowed and 100 supplied to the MP AND 50 available from the SP, THEN it returns a lower rate because U<Ub", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("100"), // 100 supplied to MP
          parseUnits("50") // 50 available from SP
        );
        // 0.0495/(1.1-(80/150))-0.025
        expect(rate).to.be.closeTo(parseUnits(".06235294117647058"), 100);
      });

      it("WHEN asking for the interest with 80 tokens borrowed and 50 supplied to the MP AND 150 available from the SP, THEN it returns a lower rate because U<Ub", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("50"), // 50 supplied to MP
          parseUnits("100") // 100 available from SP
        );
        // 0.0495/(1.1-(80/150))-0.025
        expect(rate).to.be.closeTo(parseUnits(".06235294117647058"), 100);
      });
    });

    it("WHEN asking for the interest at 0% utilization rate THEN it returns R0=0.02", async () => {
      const rate = await interestRateModel.getFeeToBorrow(
        nextPoolID,
        nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
        parseUnits("0"), // 0 borrows, this is what makes U=0
        parseUnits("0"), // no MP supply
        parseUnits("100") // 100 available from SP
      );
      expect(rate).to.eq(parseUnits("0.02"));
    });
    it("AND WHEN asking for the interest at 80% (Ub)utilization rate THEN it returns Rb=0.14", async () => {
      const rate = await interestRateModel.getFeeToBorrow(
        nextPoolID,
        nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
        parseUnits("80"), // 80 borrowed, this is what makes U=0.8
        parseUnits("0"), // no MP supply
        parseUnits("100") // 100 available from SP
      );
      expect(rate).to.eq(parseUnits("0.14"));
    });
    describe("high utilization rates", () => {
      it("AND WHEN asking for the interest at 90% (>Ub)utilization rate THEN it returns R=0.22 (price hike)", async () => {
        let rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("90"), // 90 borrowed, this is what makes U=0.9
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );
        expect(rate).to.eq(parseUnits("0.2225"));

        rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("90"), // 90 borrowed, this is what makes U=0.9
          parseUnits("100"), // MP supply
          parseUnits("0") // nothing available from SP
        );
        expect(rate).to.eq(parseUnits("0.2225"));
      });
      it("AND WHEN asking for the interest at 100% (>Ub)utilization rate THEN it returns R=0.47 (price hike)", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY,
          parseUnits("100"),
          parseUnits("10"),
          parseUnits("90")
        );
        expect(rate).to.eq(parseUnits("0.47"));
      });
      it("AND WHEN asking for the interest at 105% (close to Umax)utilization rate THEN it returns R=0.965 (price hike)", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY,
          parseUnits("105"),
          parseUnits("0"),
          parseUnits("100")
        );
        expect(rate).to.eq(parseUnits("0.965"));
      });
      it("AND WHEN asking for the interest at Umax, THEN it reverts", async () => {
        const tx = interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY,
          parseUnits("110"),
          parseUnits("50"),
          parseUnits("50")
        );

        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.EXCEEDED_MAX_UTILIZATION_RATE)
        );
      });
      it("AND WHEN asking for the interest at U>Umax, THEN it reverts", async () => {
        const tx = interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY,
          parseUnits("115"),
          parseUnits("80"),
          parseUnits("20")
        );

        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.EXCEEDED_MAX_UTILIZATION_RATE)
        );
      });
    });
    describe("interest for durations other than a full year", () => {
      it("WHEN asking for the interest for negative time difference, THEN it reverts", async () => {
        const tx = interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID + exaTime.ONE_DAY,
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );

        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.INVALID_TIME_DIFFERENCE)
        );
      });
      it("WHEN asking for the interest for a time difference of zero, THEN it reverts", async () => {
        const tx = interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID,
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );

        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.INVALID_TIME_DIFFERENCE)
        );
      });
      it("WHEN asking for the interest for a 5-day period at Ub, THEN it returns Rb*(5/365)", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 5 * exaTime.ONE_DAY,
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );

        // 0.14*5/365
        expect(rate).to.closeTo(parseUnits(".00191780821917808"), 100);
      });
      it("WHEN asking for the interest for a two-week period at Ub, THEN it returns Rb*(14/365)", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 14 * exaTime.ONE_DAY,
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );

        // 0.14*14/365
        expect(rate).to.be.closeTo(parseUnits(".00536986301369863"), 100);
      });
      it("WHEN asking for the interest for a one-day period at U0, THEN it returns R0*(1/365)", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - exaTime.ONE_DAY,
          parseUnits("0"), // 0 borrowed, this is what makes U=0
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );

        // 0.02*1/365
        // .00005479452054794520
        expect(rate).to.be.closeTo(parseUnits(".00005479452054794"), 100);
      });

      it("WHEN asking for the interest for a five-second period at U0, THEN it returns R0*(5/(365*24*60*60))", async () => {
        const rate = await interestRateModel.getFeeToBorrow(
          nextPoolID,
          nextPoolID - 5,
          parseUnits("0"), // 0 borrowed, this is what makes U=0
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );

        // 0.02*5/(365*24*60*60)
        expect(rate).to.be.closeTo(parseUnits(".00000000317097919"), 100);
      });
    });
  });

  describe("getYieldForDeposit without a spFeeRate (0%)", () => {
    it("WHEN suppliedSP is 100, unassignedEarnings are 100, and amount deposited is 100, THEN earningsShare is 100 (0 for the SP)", async () => {
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("100"),
        parseUnits("100"),
        parseUnits("100")
      );

      expect(result[0]).to.equal(parseUnits("100"));
      expect(result[1]).to.equal(parseUnits("0"));
    });

    it("WHEN suppliedSP is 101, unassignedEarnings are 100, and amount deposited is 100, THEN earningsShare is 99.0099... (0 for the SP)", async () => {
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("101"),
        parseUnits("100"),
        parseUnits("100")
      );

      expect(result[0]).to.closeTo(
        parseUnits("99.00990099"),
        parseUnits("00.00000001").toNumber()
      );
      expect(result[1]).to.eq(parseUnits("0"));
    });

    it("WHEN suppliedSP is 200, unassignedEarnings are 100, and amount deposited is 100, THEN earningsShare is 50 (0 for the SP)", async () => {
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("200"),
        parseUnits("100"),
        parseUnits("100")
      );

      expect(result[0]).to.equal(parseUnits("50"));
      expect(result[1]).to.equal(parseUnits("0"));
    });

    it("WHEN suppliedSP is 0, unassignedEarnings are 100, and amount deposited is 100, THEN earningsShare is 0 (0 for the SP)", async () => {
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("0"),
        parseUnits("100"),
        parseUnits("100")
      );

      expect(result[0]).to.equal(parseUnits("0"));
      expect(result[1]).to.equal(parseUnits("0"));
    });

    it("WHEN suppliedSP is 100, unassignedEarnings are 0, and amount deposited is 100, THEN earningsShare is 0 (0 for the SP)", async () => {
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("100"),
        parseUnits("0"),
        parseUnits("100")
      );

      expect(result[0]).to.equal(parseUnits("0"));
      expect(result[1]).to.equal(parseUnits("0"));
    });

    it("WHEN suppliedSP is 100, unassignedEarnings are 100, and amount deposited is 0, THEN earningsShare is 0 (0 for the SP)", async () => {
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("100"),
        parseUnits("100"),
        parseUnits("0")
      );

      expect(result[0]).to.equal(parseUnits("0"));
      expect(result[1]).to.equal(parseUnits("0"));
    });
  });

  describe("getYieldForDeposit with a custom spFeeRate, suppliedSP of 100, unassignedEarnings of 100 and amount deposited of 100", () => {
    it("WHEN spFeeRate is 50%, THEN earningsShare is 50 (50 for the SP)", async () => {
      await interestRateModel.setSPFeeRate(parseUnits("0.5"));
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("100"),
        parseUnits("100"),
        parseUnits("100")
      );

      expect(result[0]).to.equal(parseUnits("50"));
      expect(result[1]).to.equal(parseUnits("50"));
    });

    it("WHEN spFeeRate is 100%, THEN earningsShare is 0 (100 for the SP)", async () => {
      await interestRateModel.setSPFeeRate(parseUnits("1"));
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("100"),
        parseUnits("100"),
        parseUnits("100")
      );

      expect(result[0]).to.equal(parseUnits("0"));
      expect(result[1]).to.equal(parseUnits("100"));
    });

    it("WHEN spFeeRate is 30%, THEN earningsShare is 70 (30 for the SP)", async () => {
      await interestRateModel.setSPFeeRate(parseUnits("0.3"));
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("100"),
        parseUnits("100"),
        parseUnits("100")
      );

      expect(result[0]).to.eq(parseUnits("70"));
      expect(result[1]).to.eq(parseUnits("30"));
    });

    it("WHEN spFeeRate is 30% AND suppliedSP is 101 THEN earningsShare is 69.3069... (29.7029... for the SP)", async () => {
      await interestRateModel.setSPFeeRate(parseUnits("0.3"));
      const result = await interestRateModel.getYieldForDeposit(
        parseUnits("101"),
        parseUnits("100"),
        parseUnits("100")
      );

      expect(result[0]).to.closeTo(
        parseUnits("69.30693069"),
        parseUnits("00.00000001").toNumber()
      );
      expect(result[1]).to.closeTo(
        parseUnits("29.70297029"),
        parseUnits("00.00000001").toNumber()
      );
    });
  });

  it("WHEN calling setSPFeeRate function, THEN it should update spFeeRate", async () => {
    await interestRateModel.setSPFeeRate(parseUnits("0.5"));
    expect(await interestRateModel.spFeeRate()).to.eq(parseUnits("0.5"));
  });

  it("WHEN an unauthorized user calls setSPFeeRate function, THEN it should revert", async () => {
    await expect(
      interestRateModel.connect(alice).setSPFeeRate(parseUnits("0"))
    ).to.be.revertedWith("AccessControl");
  });

  it("WHEN an unauthorized user calls setCurveParameters function, THEN it should revert", async () => {
    const A = parseUnits("0.092"); // A parameter for the curve
    const B = parseUnits("-0.086666666666666666"); // B parameter for the curve
    const maxUtilizationRate = parseUnits("1.2"); // Maximum utilization rate
    await expect(
      interestRateModel
        .connect(alice)
        .setCurveParameters(A, B, maxUtilizationRate)
    ).to.be.revertedWith("AccessControl");
  });
});
