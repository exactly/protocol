// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { DSTestPlus } from "@rari-capital/solmate/src/test/utils/DSTestPlus.sol";
import { FixedPointMathLib } from "@rari-capital/solmate-v6/src/utils/FixedPointMathLib.sol";
import { MockInterestRateModel } from "../../contracts/mocks/MockInterestRateModel.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { Auditor } from "../../contracts/Auditor.sol";
import { MockToken } from "../../contracts/mocks/MockToken.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { FixedLender, ERC20, IAuditor, IInterestRateModel } from "../../contracts/FixedLender.sol";

contract FixedLenderTest is DSTestPlus {
  address internal constant BOB = address(69);
  address internal constant ALICE = address(70);

  Vm internal vm = Vm(HEVM_ADDRESS);
  FixedLender internal fixedLender;
  Auditor internal auditor;
  MockInterestRateModel internal mockInterestRateModel;
  MockOracle internal mockOracle;
  string[] private tokens = ["DAI", "USDC", "WETH", "WBTC"];

  event Transfer(address indexed from, address indexed to, uint256 amount);
  event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
  event Withdraw(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
  event DepositAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed owner,
    uint256 assets,
    uint256 fee
  );
  event WithdrawAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed owner,
    uint256 assets,
    uint256 assetsDiscounted
  );
  event BorrowAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 fee
  );
  event RepayAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed borrower,
    uint256 assets,
    uint256 debtCovered
  );

  function setUp() external {
    MockToken mockToken = new MockToken("DAI", "DAI", 18, 150_000 ether);
    mockOracle = new MockOracle();
    mockOracle.setPrice("DAI", 1e18);
    auditor = new Auditor(mockOracle, 1.1e18);
    mockInterestRateModel = new MockInterestRateModel(0.1e18);
    mockInterestRateModel.setSPFeeRate(1e17);

    fixedLender = new FixedLender(
      mockToken,
      "DAI",
      12,
      1e18,
      auditor,
      mockInterestRateModel,
      0.02e18 / uint256(1 days),
      0
    );

    auditor.enableMarket(fixedLender, 0.8e18, "DAI", "DAI", 18);

    vm.label(BOB, "Bob");
    vm.label(ALICE, "Alice");
    mockToken.transfer(BOB, 50_000 ether);
    mockToken.transfer(ALICE, 50_000 ether);
    mockToken.approve(address(fixedLender), 50_000 ether);
    vm.prank(BOB);
    mockToken.approve(address(fixedLender), 50_000 ether);
    vm.prank(ALICE);
    mockToken.approve(address(fixedLender), 50_000 ether);
  }

  function testDepositToSmartPool() external {
    vm.expectEmit(true, true, true, true);
    emit Deposit(address(this), address(this), 1 ether, 1 ether);

    fixedLender.deposit(1 ether, address(this));
  }

  function testWithdrawFromSmartPool() external {
    fixedLender.deposit(1 ether, address(this));

    vm.expectEmit(true, true, true, true);
    emit Transfer(address(fixedLender), address(this), 1 ether);
    fixedLender.withdraw(1 ether, address(this), address(this));
  }

  function testDepositAtMaturity() external {
    vm.expectEmit(true, true, true, true);
    emit DepositAtMaturity(7 days, address(this), address(this), 1 ether, 0);
    fixedLender.depositAtMaturity(7 days, 1 ether, 1 ether, address(this));
  }

  function testWithdrawAtMaturity() external {
    fixedLender.depositAtMaturity(7 days, 1 ether, 1 ether, address(this));

    vm.expectEmit(true, true, true, true);
    // TODO: fix wrong hardcoded value
    emit WithdrawAtMaturity(7 days, address(this), address(this), address(this), 1 ether, 909090909090909090);
    fixedLender.withdrawAtMaturity(7 days, 1 ether, 0.9 ether, address(this), address(this));
  }

  function testBorrowAtMaturity() external {
    fixedLender.deposit(12 ether, address(this));

    vm.expectEmit(true, true, true, true);
    emit BorrowAtMaturity(7 days, address(this), address(this), address(this), 1 ether, 0.1 ether);
    fixedLender.borrowAtMaturity(7 days, 1 ether, 2 ether, address(this), address(this));
  }

  function testRepayAtMaturity() external {
    fixedLender.deposit(12 ether, address(this));
    fixedLender.borrowAtMaturity(7 days, 1 ether, 1.1 ether, address(this), address(this));

    vm.expectEmit(true, true, true, true);
    emit RepayAtMaturity(7 days, address(this), address(this), 1.01 ether, 1.1 ether);
    fixedLender.repayAtMaturity(7 days, 1.5 ether, 1.5 ether, address(this));
  }

  function testMultipleDepositsToSmartPool() external {
    fixedLender.deposit(1 ether, address(this));
    fixedLender.deposit(1 ether, address(this));
    fixedLender.deposit(1 ether, address(this));
    fixedLender.deposit(1 ether, address(this));
    fixedLender.deposit(1 ether, address(this));
    fixedLender.deposit(1 ether, address(this));
    fixedLender.deposit(1 ether, address(this));
  }

  function testSmartPoolEarningsDistribution() external {
    vm.prank(BOB);
    fixedLender.deposit(10_000 ether, BOB);

    vm.warp(7 days);

    vm.prank(BOB);
    fixedLender.borrowAtMaturity(7 days * 2, 1_000 ether, 1_100 ether, BOB, BOB);

    vm.warp(7 days + 3.5 days);
    fixedLender.deposit(10_000 ether, address(this));
    assertEq(fixedLender.balanceOf(BOB), 10_000 ether);
    assertEq(fixedLender.maxWithdraw(address(this)), 10_000 ether - 1);
    assertRelApproxEq(fixedLender.balanceOf(address(this)), 9950 ether, 2.5e13);

    vm.warp(7 days + 5 days);
    fixedLender.deposit(1_000 ether, address(this));
    assertRelApproxEq(fixedLender.balanceOf(address(this)), 10944 ether, 2.5e13);
  }

  function testSmartPoolSharesDoNotAccountUnassignedEarningsFromMoreThanOneIntervalPastMaturities() external {
    uint256 maturity = 7 days * 2;
    fixedLender.deposit(10_000 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    // we move to the last second before an interval (7 days) goes by after the maturity passed
    vm.warp(7 days * 2 + 6 days + 23 hours + 59 minutes + 59 seconds);
    assertTrue(
      fixedLender.previewDeposit(10_000 ether) != fixedLender.balanceOf(address(this)),
      "shares received should be less"
    );

    // we move to the instant where an interval went by after the maturity passed
    vm.warp(7 days * 3);
    // the unassigned earnings of the maturity that the contract borrowed from are not accounted anymore
    assertEq(fixedLender.previewDeposit(10_000 ether), fixedLender.balanceOf(address(this)));
  }

  function testPreviewOperationsWithSmartPoolCorrectlyAccountingEarnings() external {
    uint256 assets = 10_000 ether;
    uint256 maturity = 7 days * 2;
    uint256 anotherMaturity = 7 days * 3;
    fixedLender.deposit(assets, address(this));

    vm.warp(7 days);
    fixedLender.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    vm.prank(BOB);
    fixedLender.deposit(10_000 ether, BOB);
    vm.prank(BOB); // we have unassigned earnings
    fixedLender.borrowAtMaturity(anotherMaturity, 1_000 ether, 1_100 ether, BOB, BOB);

    vm.warp(maturity + 1 days / 2); // and we have penalties -> delayed half a day
    fixedLender.repayAtMaturity(maturity, 1_111 ether, 1_111 ether, address(this));

    assertEq(
      fixedLender.previewRedeem(fixedLender.balanceOf(address(this))),
      fixedLender.redeem(fixedLender.balanceOf(address(this)), address(this), address(this))
    );

    vm.warp(maturity + 2 days);
    fixedLender.deposit(assets, address(this));
    vm.warp(maturity + 4 days); // a more relevant portion of the accumulator is distributed after 2 days
    assertEq(fixedLender.previewWithdraw(assets), fixedLender.withdraw(assets, address(this), address(this)));

    vm.warp(maturity + 5 days);
    assertEq(fixedLender.previewDeposit(assets), fixedLender.deposit(assets, address(this)));
    vm.warp(maturity + 6 days);
    assertEq(fixedLender.previewMint(10_000 ether), fixedLender.mint(10_000 ether, address(this)));
  }

  function testFrontRunSmartPoolEarningsDistributionWithBigPenaltyRepayment() external {
    uint256 maturity = 7 days * 2;
    fixedLender.deposit(10_000 ether, address(this));

    vm.warp(7 days);
    fixedLender.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    vm.warp(maturity);
    fixedLender.borrowAtMaturity(maturity, 0, 0, address(this), address(this)); // we send tx to accrue earnings

    vm.warp(7 days * 3 + 6 days + 23 hours + 59 seconds);
    vm.prank(BOB);
    fixedLender.deposit(10_100 ether, BOB); // bob deposits more assets to have same shares as previous user
    assertEq(fixedLender.balanceOf(BOB), 10_000 ether);
    uint256 assetsBobBefore = fixedLender.convertToAssets(fixedLender.balanceOf(address(this)));
    assertEq(assetsBobBefore, fixedLender.convertToAssets(fixedLender.balanceOf(address(this))));

    vm.warp(7 days * 4); // 2 weeks delayed (2% daily = 28% in penalties), 1100 * 1.28 = 1408
    fixedLender.repayAtMaturity(maturity, 1_408 ether, 1_408 ether, address(this));
    // no penalties are accrued (accumulator accounts them)

    // 59 minutes and + 1 second passed since bob's deposit -> he now has 75100318255611032 more if he withdraws
    assertEq(fixedLender.convertToAssets(fixedLender.balanceOf(BOB)), assetsBobBefore + 75100318255611032);
    assertRelApproxEq(fixedLender.smartPoolEarningsAccumulator(), 308 ether, 1e7);

    vm.warp(7 days * 5);
    // then the accumulator will distribute 7.73% since 7.73 * 13 = 100 (13 because we add 1 maturity in the division)
    // 308e18 * 0.07 = 238e17
    vm.prank(ALICE);
    fixedLender.deposit(10_100 ether, ALICE); // alice deposits same assets amount as previous users
    assertRelApproxEq(fixedLender.smartPoolEarningsAccumulator(), 308 ether - 238e17, 1e14);
    // bob earns half the earnings distributed
    assertRelApproxEq(fixedLender.convertToAssets(fixedLender.balanceOf(BOB)), assetsBobBefore + 238e17 / 2, 1e14);
  }

  function testDistributeMultipleAccumulatedEarnings() external {
    uint256 maturity = 7 days * 2;
    fixedLender.deposit(10_000 ether, address(this));
    fixedLender.depositAtMaturity(maturity, 1_000 ether, 1_000 ether, address(this));

    vm.warp(7 days);
    fixedLender.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    vm.warp(7 days * 4); // 2 weeks delayed (2% daily = 28% in penalties), 1100 * 1.28 = 1408
    fixedLender.repayAtMaturity(maturity, 1_408 ether, 1_408 ether, address(this));
    // no penalties are accrued (accumulator accounts all of them since borrow uses mp deposits)
    assertRelApproxEq(fixedLender.smartPoolEarningsAccumulator(), 408 ether, 1e7);

    vm.warp(7 days * 5);
    vm.prank(BOB);
    fixedLender.deposit(10_000 ether, BOB);

    uint256 balanceBobAfterFirstDistribution = fixedLender.convertToAssets(fixedLender.balanceOf(BOB));
    uint256 balanceContractAfterFirstDistribution = fixedLender.convertToAssets(fixedLender.balanceOf(address(this)));
    uint256 accumulatedEarningsAfterFirstDistribution = fixedLender.smartPoolEarningsAccumulator();

    // 119 ether are distributed from the accumulator
    assertRelApproxEq(balanceContractAfterFirstDistribution, 10_119 ether, 1e16);
    assertApproxEq(balanceBobAfterFirstDistribution, 10_000 ether, 1);
    assertRelApproxEq(accumulatedEarningsAfterFirstDistribution, 408 ether - 119 ether, 1e16);
    assertEq(fixedLender.lastAccumulatedEarningsAccrual(), 7 days * 5);

    vm.warp(7 days * 6);
    fixedLender.deposit(1_000 ether, address(this));

    uint256 balanceBobAfterSecondDistribution = fixedLender.convertToAssets(fixedLender.balanceOf(BOB));
    uint256 balanceContractAfterSecondDistribution = fixedLender.convertToAssets(fixedLender.balanceOf(address(this)));
    uint256 accumulatedEarningsAfterSecondDistribution = fixedLender.smartPoolEarningsAccumulator();

    uint256 earningsDistributed = balanceBobAfterSecondDistribution -
      balanceBobAfterFirstDistribution +
      balanceContractAfterSecondDistribution -
      balanceContractAfterFirstDistribution -
      1_000 ether; // new deposited eth
    uint256 earningsToBob = 11010857929329808864;
    uint256 earningsToContract = 11142988224481559099;

    assertEq(
      accumulatedEarningsAfterFirstDistribution - accumulatedEarningsAfterSecondDistribution,
      earningsDistributed
    );
    assertEq(earningsToBob + earningsToContract, earningsDistributed);
    assertEq(balanceBobAfterSecondDistribution, balanceBobAfterFirstDistribution + earningsToBob);
    assertEq(
      balanceContractAfterSecondDistribution,
      balanceContractAfterFirstDistribution + earningsToContract + 1_000 ether
    );
    assertEq(fixedLender.lastAccumulatedEarningsAccrual(), 7 days * 6);
  }

  function testUpdateAccumulatedEarningsFactorToZero() external {
    uint256 maturity = 7 days * 2;
    fixedLender.deposit(10_000 ether, address(this));

    vm.warp(7 days);
    fixedLender.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    // accumulator accounts 10% of the fees, spFeeRate -> 0.1
    fixedLender.depositAtMaturity(maturity, 1_000 ether, 1_000 ether, address(this));
    assertEq(fixedLender.smartPoolEarningsAccumulator(), 10 ether);

    vm.warp(7 days * 3);
    fixedLender.deposit(1_000 ether, address(this));
    // 20% was distributed
    assertEq(fixedLender.convertToAssets(fixedLender.balanceOf(address(this))), 11_002 ether);
    assertEq(fixedLender.smartPoolEarningsAccumulator(), 8 ether);

    // we set the factor to 0 and all is distributed in the following tx
    fixedLender.setAccumulatedEarningsSmoothFactor(0);
    vm.warp(7 days * 3 + 1 seconds);
    fixedLender.deposit(1 ether, address(this));
    assertEq(fixedLender.convertToAssets(fixedLender.balanceOf(address(this))), 11_011 ether);
    assertEq(fixedLender.smartPoolEarningsAccumulator(), 0);

    // accumulator has 0 earnings so nothing is distributed
    vm.warp(7 days * 4);
    fixedLender.deposit(1 ether, address(this));
    assertEq(fixedLender.convertToAssets(fixedLender.balanceOf(address(this))), 11_012 ether);
    assertEq(fixedLender.smartPoolEarningsAccumulator(), 0);
  }

  function testFailRoundingUpAllowanceWhenBorrowingAtMaturity() external {
    uint256 maturity = 7 days * 2;

    fixedLender.deposit(10_000 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1 ether, 1.1 ether, address(this), address(this));
    vm.warp(7 days);
    // we accrue earnings with this tx so we break proportion of 1 to 1 assets and shares
    fixedLender.borrowAtMaturity(maturity, 1 ether, 1.1 ether, address(this), address(this));

    vm.warp(7 days + 3 days);
    vm.prank(BOB);
    // we try to borrow 1 unit on behalf of this contract as bob being msg.sender without allowance
    // if it correctly rounds up, it should fail
    fixedLender.borrowAtMaturity(maturity, 1, 2, BOB, address(this));
  }

  function testFailRoundingUpAllowanceWhenWithdrawingAtMaturity() external {
    uint256 maturity = 7 days * 2;

    fixedLender.deposit(10_000 ether, address(this));
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));
    vm.warp(7 days);
    // we accrue earnings with this tx so we break proportion of 1 to 1 assets and shares
    fixedLender.borrowAtMaturity(maturity, 1 ether, 1.1 ether, address(this), address(this));

    vm.warp(maturity);
    vm.prank(BOB);
    // we try to withdraw 1 unit on behalf of this contract as bob being msg.sender without allowance
    // if it correctly rounds up, it should fail
    fixedLender.withdrawAtMaturity(maturity, 1, 0, BOB, address(this));
  }

  function testFailRoundingUpAssetsToValidateShortfallWhenTransferringFrom() external {
    MockToken mockToken = new MockToken("DAI", "DAI", 18, 150_000 ether);

    // we deploy a harness fixedlender to be able to set different supply and smartPoolBalance
    FixedLenderHarness fixedLenderHarness = new FixedLenderHarness(
      mockToken,
      "DAI",
      12,
      1e18,
      auditor,
      mockInterestRateModel,
      0.02e18 / uint256(1 days),
      0
    );
    uint256 maturity = 7 days * 2;
    mockToken.approve(address(fixedLenderHarness), 50_000 ether);
    fixedLenderHarness.approve(BOB, 50_000 ether);
    auditor.enableMarket(fixedLenderHarness, 0.8e18, "DAI", "DAI", 18);

    fixedLenderHarness.setSmartPoolBalance(500 ether);
    fixedLenderHarness.setSupply(2000 ether);

    fixedLenderHarness.deposit(1000 ether, address(this));
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderHarness.borrowAtMaturity(maturity, 800 ether, 800 ether, address(this), address(this));

    // we try to transfer 5 shares, if it correctly rounds up to 2 withdraw amount then it should fail
    // if it rounds down to 1, it will pass
    vm.prank(BOB);
    fixedLenderHarness.transferFrom(address(this), BOB, 5);
  }

  function testFailRoundingUpAssetsToValidateShortfallWhenTransferring() external {
    MockToken mockToken = new MockToken("DAI", "DAI", 18, 150_000 ether);

    // we deploy a harness fixedlender to be able to set different supply and smartPoolBalance
    FixedLenderHarness fixedLenderHarness = new FixedLenderHarness(
      mockToken,
      "DAI",
      12,
      1e18,
      auditor,
      mockInterestRateModel,
      0.02e18 / uint256(1 days),
      0
    );
    uint256 maturity = 7 days * 2;
    mockToken.approve(address(fixedLenderHarness), 50_000 ether);
    auditor.enableMarket(fixedLenderHarness, 0.8e18, "DAI", "DAI", 18);

    fixedLenderHarness.setSmartPoolBalance(500 ether);
    fixedLenderHarness.setSupply(2000 ether);

    fixedLenderHarness.deposit(1000 ether, address(this));
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderHarness.borrowAtMaturity(maturity, 800 ether, 800 ether, address(this), address(this));

    // we try to transfer 5 shares, if it correctly rounds up to 2 withdraw amount then it should fail
    // if it rounds down to 1, it will pass
    fixedLenderHarness.transfer(BOB, 5);
  }

  function testMultipleBorrowsForMultipleAssets() external {
    FixedLender[4] memory fixedLenders;
    for (uint256 i = 0; i < tokens.length; i++) {
      string memory tokenName = tokens[i];

      MockToken mockToken = new MockToken(tokenName, tokenName, 18, 150_000 ether);
      FixedLender newFixedLender = new FixedLender(
        mockToken,
        tokenName,
        12,
        1e18,
        auditor,
        mockInterestRateModel,
        0.02e18 / uint256(1 days),
        0
      );
      auditor.enableMarket(newFixedLender, 0.8e18, tokenName, tokenName, 18);
      mockOracle.setPrice(tokenName, 1e8);
      mockToken.approve(address(newFixedLender), 50_000 ether);
      mockToken.transfer(BOB, 110 ether);
      vm.prank(BOB);
      mockToken.approve(address(newFixedLender), 110 ether);

      fixedLenders[i] = newFixedLender;

      newFixedLender.deposit(5_000 ether, address(this));
    }

    // since 224 is the max amount of consecutive maturities where a user can borrow
    // 204 is the last valid cycle (the last maturity where it borrows is 216)
    for (uint256 i = 0; i < 205; i += 12) {
      multipleBorrowsAtMaturity(fixedLenders, i + 1, 7 days * i);
    }

    // repay does not increase in cost
    fixedLenders[0].repayAtMaturity(7 days, 1 ether, 1 ether, address(this));
    // withdraw DOES increase in cost
    fixedLenders[0].withdraw(1 ether, address(this), address(this));

    // normal operations of another user are not impacted
    vm.prank(BOB);
    fixedLenders[0].deposit(100 ether, address(BOB));
    vm.prank(BOB);
    fixedLenders[0].withdraw(1 ether, address(BOB), address(BOB));
    vm.prank(BOB);
    vm.warp(7 days * 400);
    fixedLenders[0].borrowAtMaturity(7 days * 401, 1 ether, 1.2 ether, address(BOB), address(BOB));

    // liquidate function to user's borrows DOES increase in cost
    vm.prank(BOB);
    fixedLenders[0].liquidate(address(this), 1 ether, 1 ether, fixedLenders[0], 7 days * 2);
  }

  function multipleBorrowsAtMaturity(
    FixedLender[4] memory fixedLenders,
    uint256 initialMaturity,
    uint256 initialTime
  ) internal {
    vm.warp(initialTime);
    for (uint256 i = 0; i < fixedLenders.length; i++) {
      for (uint256 j = initialMaturity; j < initialMaturity + 12; j++) {
        fixedLenders[i].borrowAtMaturity(7 days * j, 1 ether, 1.2 ether, address(this), address(this));
      }
    }
  }
}

contract FixedLenderHarness is FixedLender {
  constructor(
    ERC20 asset_,
    string memory assetSymbol_,
    uint8 maxFuturePools_,
    uint256 accumulatedEarningsSmoothFactor_,
    IAuditor auditor_,
    IInterestRateModel interestRateModel_,
    uint256 penaltyRate_,
    uint256 smartPoolReserveFactor_
  )
    FixedLender(
      asset_,
      assetSymbol_,
      maxFuturePools_,
      accumulatedEarningsSmoothFactor_,
      auditor_,
      interestRateModel_,
      penaltyRate_,
      smartPoolReserveFactor_
    )
  {}

  function setSupply(uint256 supply) external {
    totalSupply = supply;
  }

  function setSmartPoolBalance(uint256 balance) external {
    smartPoolBalance = balance;
  }
}
