// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

import { Auditor, Market, InsufficientAccountLiquidity } from "../contracts/Auditor.sol";
import { IntegrationPreviewer } from "../contracts/periphery/IntegrationPreviewer.sol";
import { InterestRateModel } from "../contracts/InterestRateModel.sol";
import { ForkTest } from "./Fork.t.sol";

contract IntegrationPreviewerTest is ForkTest {
  using FixedPointMathLib for uint256;

  address internal constant USER = 0x291019ecdA53f4E841f6722fEf239C9Dd120e6d5;

  address internal timelock;
  Auditor internal auditor;
  Market internal exaUSDC;
  IntegrationPreviewer internal previewer;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 122_565_907);

    timelock = deployment("TimelockController");
    auditor = Auditor(deployment("Auditor"));
    exaUSDC = Market(deployment("MarketUSDC"));
    exaUSDC = Market(deployment("MarketUSDC"));
    previewer = IntegrationPreviewer(address(new ERC1967Proxy(address(new IntegrationPreviewer(auditor)), "")));
    deployment("RewardsController");
    deployment("PriceFeedOP");
    deployment("PriceFeedUSDC");
    deployment("PriceFeedUSDC.e");
    deployment("PriceFeedWBTC");
    deployment("PriceFeedWETH");
    deployment("MarketOP");
    deployment("MarketUSDC.e");
    deployment("MarketWBTC");
    deployment("MarketWETH");
    deployment("USDC");
    vm.label(address(previewer), "IntegrationPreviewer");
    vm.label(address(exaUSDC.interestRateModel()), "InterestRateModelUSDC");
    vm.label(address(Market(deployment("MarketOP")).interestRateModel()), "InterestRateModelOP");
    vm.label(address(Market(deployment("MarketUSDC.e")).interestRateModel()), "InterestRateModelUSDC.e");
    vm.label(address(Market(deployment("MarketWBTC")).interestRateModel()), "InterestRateModelWBTC");
    vm.label(address(Market(deployment("MarketWETH")).interestRateModel()), "InterestRateModelWETH");

    Market[] memory markets = auditor.allMarkets();
    for (uint256 i = 0; i < markets.length; ++i) {
      upgrade(address(markets[i]), address(new Market(markets[i].asset(), auditor)));
    }
  }

  // solhint-disable func-name-mixedcase

  function test_healthFactor() external view {
    assertEq(previewer.healthFactor(USER), 1.135305841449548453e18);
    assertEq(previewer.healthFactor(address(0)), type(uint256).max);
  }

  function test_borrowLimit() external {
    vm.startPrank(USER);
    exaUSDC.borrow(previewer.borrowLimit(USER, exaUSDC, 1e18) - 1, USER, USER);
    assertEq(previewer.borrowLimit(USER, exaUSDC, 1e18), 0);

    vm.expectRevert(InsufficientAccountLiquidity.selector);
    exaUSDC.borrow(1, USER, USER);
  }

  function test_fixedRepayAssets_beforeMaturity() external {
    uint256 maturity = 1_734_566_400;
    uint256 positionAssets = 420e6;

    uint256 repayAssets = previewer.fixedRepayAssets(USER, exaUSDC, maturity, positionAssets);

    vm.startPrank(USER);
    deal(address(exaUSDC.asset()), USER, 1_000_000e6);
    exaUSDC.asset().approve(address(exaUSDC), type(uint256).max);
    uint256 actualRepayAssets = exaUSDC.repayAtMaturity(maturity, positionAssets, type(uint256).max, USER);

    assertEq(actualRepayAssets, repayAssets);
  }

  function test_fixedRepayAssets_afterMaturity() external {
    uint256 maturity = 1_734_566_400;
    uint256 positionAssets = 420e6;

    skip(55 weeks);

    uint256 repayAssets = previewer.fixedRepayAssets(USER, exaUSDC, maturity, positionAssets);

    vm.startPrank(USER);
    deal(address(exaUSDC.asset()), USER, 1_000_000e6);
    exaUSDC.asset().approve(address(exaUSDC), type(uint256).max);
    uint256 actualRepayAssets = exaUSDC.repayAtMaturity(maturity, positionAssets, type(uint256).max, USER);

    assertEq(actualRepayAssets, repayAssets);
  }

  function test_fixedRepayAssets_maxUintBeforeMaturity() external {
    uint256 maturity = 1_734_566_400;
    uint256 positionAssets = type(uint256).max;

    uint256 repayAssets = previewer.fixedRepayAssets(USER, exaUSDC, maturity, positionAssets);

    vm.startPrank(USER);
    deal(address(exaUSDC.asset()), USER, 1_000_000e6);
    exaUSDC.asset().approve(address(exaUSDC), type(uint256).max);
    uint256 actualRepayAssets = exaUSDC.repayAtMaturity(maturity, positionAssets, type(uint256).max, USER);

    assertEq(actualRepayAssets, repayAssets);
  }

  function test_fixedRepayAssets_maxUintAfterMaturity() external {
    uint256 maturity = 1_734_566_400;
    uint256 positionAssets = type(uint256).max;

    skip(55 weeks);

    uint256 repayAssets = previewer.fixedRepayAssets(USER, exaUSDC, maturity, positionAssets);

    vm.startPrank(USER);
    deal(address(exaUSDC.asset()), USER, 1_000_000e6);
    exaUSDC.asset().approve(address(exaUSDC), type(uint256).max);
    uint256 actualRepayAssets = exaUSDC.repayAtMaturity(maturity, positionAssets, type(uint256).max, USER);

    assertEq(actualRepayAssets, repayAssets);
  }

  function test_fixedRepayPosition_beforeMaturity() external {
    uint256 maturity = 1_734_566_400;
    uint256 repayAssets = 420e6;

    uint256 positionAssets = previewer.fixedRepayPosition(USER, exaUSDC, maturity, repayAssets);

    vm.startPrank(USER);
    deal(address(exaUSDC.asset()), USER, 1_000_000e6);
    exaUSDC.asset().approve(address(exaUSDC), type(uint256).max);
    uint256 actualRepayAssets = exaUSDC.repayAtMaturity(maturity, positionAssets, type(uint256).max, USER);

    assertLe(actualRepayAssets, repayAssets);
    assertApproxEqAbs(actualRepayAssets, repayAssets, 1);
  }

  function test_fixedRepayPosition_afterMaturity() external {
    uint256 maturity = 1_734_566_400;
    uint256 repayAssets = 420e6;

    skip(55 weeks);

    uint256 positionAssets = previewer.fixedRepayPosition(USER, exaUSDC, maturity, repayAssets);

    vm.startPrank(USER);
    deal(address(exaUSDC.asset()), USER, 1_000_000e6);
    exaUSDC.asset().approve(address(exaUSDC), type(uint256).max);
    uint256 actualRepayAssets = exaUSDC.repayAtMaturity(maturity, positionAssets, type(uint256).max, USER);

    assertLe(actualRepayAssets, repayAssets);
    assertApproxEqAbs(actualRepayAssets, repayAssets, 1);
  }

  function test_fixedRepayPosition_maxUint() external {
    uint256 maturity = 1_734_566_400;
    uint256 repayAssets = type(uint256).max;
    (uint256 principal, uint256 fee) = exaUSDC.fixedBorrowPositions(maturity, USER);

    assertEq(previewer.fixedRepayPosition(USER, exaUSDC, maturity, repayAssets), principal + fee);

    skip(55 weeks);

    assertEq(previewer.fixedRepayPosition(USER, exaUSDC, maturity, repayAssets), principal + fee);
  }

  function test_fixedRepayPosition_saturatedFallback() external view {
    uint256 maturity = 1_734_566_400;
    uint256 repayAssets = 831_039_892;
    (uint256 principal, uint256 fee) = exaUSDC.fixedBorrowPositions(maturity, USER);

    assertEq(previewer.fixedRepayPosition(USER, exaUSDC, maturity, repayAssets), principal + fee);
  }

  function test_rates() external {
    Market[] memory markets = auditor.allMarkets();
    uint256[] memory totalAssets = new uint256[](markets.length);
    uint256[] memory totalFloatingBorrowAssets = new uint256[](markets.length);
    vm.startPrank(timelock);
    for (uint256 i = 0; i < markets.length; ++i) {
      markets[i].setInterestRateModel(markets[i].interestRateModel());
      totalAssets[i] = markets[i].totalAssets();
      totalFloatingBorrowAssets[i] = markets[i].totalFloatingBorrowAssets();
    }
    vm.stopPrank();
    IntegrationPreviewer.MarketRates[] memory rates = previewer.rates();
    uint256 elapsed = 1 hours;
    skip(elapsed);
    for (uint256 i = 0; i < rates.length; ++i) {
      assertEq(
        rates[i].floatingDeposit,
        (rates[i].market.totalAssets() - totalAssets[i]).mulDivDown(365 days * 1e18, elapsed * totalAssets[i]),
        "floating deposit rate mismatch"
      );
      assertEq(
        totalFloatingBorrowAssets[i].mulDivDown(rates[i].floatingBorrow * elapsed, 365 days * 1e18),
        rates[i].market.totalFloatingBorrowAssets() - totalFloatingBorrowAssets[i],
        "floating borrow rate mismatch"
      );
      for (uint256 j = 0; j < rates[i].fixedRates.length; ++j) {
        vm.prank(USER);
        rates[i].market.borrowAtMaturity(rates[i].fixedRates[j].maturity, 100, type(uint256).max, USER, USER);
      }
    }
  }

  // solhint-enable func-name-mixedcase
}
