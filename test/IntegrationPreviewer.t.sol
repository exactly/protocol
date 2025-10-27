// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";

import { Auditor, InsufficientAccountLiquidity } from "../contracts/Auditor.sol";
import { Market, InterestRateModel, ERC20 } from "../contracts/Market.sol";
import { IntegrationPreviewer } from "../contracts/periphery/IntegrationPreviewer.sol";
import { RewardsController } from "../contracts/RewardsController.sol";
import { ForkTest } from "./Fork.t.sol";

contract IntegrationPreviewerTest is ForkTest {
  using FixedPointMathLib for uint256;

  address internal constant USER = 0x738E079c7c9009040A265daa1cF53F772B19Fb18;
  uint256 internal constant MATURITY = 1_763_596_800;

  address internal timelock;
  Auditor internal auditor;
  Market internal exaUSDC;
  ERC20 internal usdc;
  IntegrationPreviewer internal previewer;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 142_772_987);

    timelock = deployment("TimelockController");
    auditor = Auditor(deployment("Auditor"));
    exaUSDC = Market(deployment("MarketUSDC"));
    exaUSDC = Market(deployment("MarketUSDC"));
    usdc = ERC20(deployment("USDC"));
    previewer = IntegrationPreviewer(address(new ERC1967Proxy(address(new IntegrationPreviewer(auditor)), "")));
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

    upgrade(address(auditor), address(new Auditor(auditor.priceDecimals())));
    upgrade(deployment("RewardsController"), address(new RewardsController()));
    Market[] memory markets = auditor.allMarkets();
    for (uint256 i = 0; i < markets.length; ++i) {
      upgrade(address(markets[i]), address(new Market(markets[i].asset(), auditor)));
      vm.startPrank(timelock);
      markets[i].initialize2(type(uint256).max);
      markets[i].setInterestRateModel(new InterestRateModel(markets[i].interestRateModel().parameters(), markets[i]));
      vm.stopPrank();
    }
  }

  // solhint-disable func-name-mixedcase

  // #region health factor

  function test_healthFactor() external view {
    assertEq(previewer.healthFactor(USER), 1.167689639007889221e18);
    assertEq(previewer.healthFactor(address(0)), type(uint256).max);
  }

  function test_borrowLimit() external {
    vm.startPrank(USER);
    exaUSDC.borrow(previewer.borrowLimit(USER, exaUSDC, 1e18) - 1, USER, USER);
    assertEq(previewer.borrowLimit(USER, exaUSDC, 1e18), 0);

    vm.expectRevert(InsufficientAccountLiquidity.selector);
    exaUSDC.borrow(1, USER, USER);
  }

  function test_previewHealthFactor() external {
    uint256 assets = 10e6;
    deal(address(usdc), USER, 1_000_000e6);
    vm.startPrank(USER);
    usdc.approve(address(exaUSDC), type(uint256).max);

    uint256 healthFactor = previewer.previewHealthFactor(USER, exaUSDC, int256(assets), 0);
    exaUSDC.deposit(assets, USER);
    assertEq(healthFactor, previewer.healthFactor(USER), "bad health factor after deposit");

    healthFactor = previewer.previewHealthFactor(
      USER,
      exaUSDC,
      -int256(exaUSDC.previewMint(exaUSDC.previewWithdraw(assets))),
      0
    );
    exaUSDC.withdraw(assets, USER, USER);
    assertEq(healthFactor, previewer.healthFactor(USER), "bad health factor after withdraw");

    (uint256 borrowed, uint256 supplied, , ) = exaUSDC.fixedPools(MATURITY);
    healthFactor = previewer.previewHealthFactor(
      USER,
      exaUSDC,
      0,
      int256(
        assets + assets.mulWadUp(exaUSDC.interestRateModel().fixedBorrowRate(MATURITY, assets, borrowed, supplied, 0))
      )
    );
    exaUSDC.borrowAtMaturity(MATURITY, assets, type(uint256).max, USER, USER);
    assertEq(healthFactor, previewer.healthFactor(USER), "bad health factor after fixed borrow");

    healthFactor = previewer.previewHealthFactor(USER, exaUSDC, 0, -int256(assets));
    exaUSDC.repayAtMaturity(MATURITY, assets, type(uint256).max, USER);
    assertEq(healthFactor, previewer.healthFactor(USER), "bad health factor after fixed repay");
  }
  // #endregion

  // #region preview operations

  function test_previewDeposit_(uint256 skipSeed) external {
    uint256 assets = 10e6;
    deal(address(usdc), USER, 1_000_000e6);
    skip(bound(skipSeed, 0, 15 weeks));

    IntegrationPreviewer.SharesPreview memory preview = previewer.previewDeposit(USER, exaUSDC, assets);

    vm.startPrank(USER);
    usdc.approve(address(exaUSDC), type(uint256).max);
    uint256 shares = exaUSDC.deposit(assets, USER);

    assertEq(preview.shares, shares, "wrong shares");
    assertEq(preview.healthFactor, previewer.healthFactor(USER), "wrong health factor");
  }

  function test_previewWithdraw_(uint256 skipSeed) external {
    uint256 assets = 10e6;
    skip(bound(skipSeed, 0, 15 weeks));

    IntegrationPreviewer.SharesPreview memory preview = previewer.previewWithdraw(USER, exaUSDC, assets);

    vm.startPrank(USER);
    uint256 shares = exaUSDC.withdraw(assets, USER, USER);

    assertEq(preview.shares, shares, "wrong shares");
    assertEq(preview.healthFactor, previewer.healthFactor(USER), "wrong health factor");
  }
  // #endregion

  // #region fixed repay

  function test_fixedRepayAssets_beforeMaturity() external {
    uint256 positionAssets = 420e6;

    uint256 repayAssets = previewer.fixedRepayAssets(USER, exaUSDC, MATURITY, positionAssets);

    vm.startPrank(USER);
    deal(address(usdc), USER, 1_000_000e6);
    usdc.approve(address(exaUSDC), type(uint256).max);
    uint256 actualRepayAssets = exaUSDC.repayAtMaturity(MATURITY, positionAssets, type(uint256).max, USER);

    assertEq(actualRepayAssets, repayAssets);
  }

  function test_fixedRepayAssets_afterMaturity() external {
    uint256 positionAssets = 420e6;
    skip(55 weeks);

    uint256 repayAssets = previewer.fixedRepayAssets(USER, exaUSDC, MATURITY, positionAssets);

    vm.startPrank(USER);
    deal(address(usdc), USER, 1_000_000e6);
    usdc.approve(address(exaUSDC), type(uint256).max);
    uint256 actualRepayAssets = exaUSDC.repayAtMaturity(MATURITY, positionAssets, type(uint256).max, USER);

    assertEq(actualRepayAssets, repayAssets);
  }

  function test_fixedRepayAssets_maxUintBeforeMaturity() external {
    uint256 positionAssets = type(uint256).max;

    uint256 repayAssets = previewer.fixedRepayAssets(USER, exaUSDC, MATURITY, positionAssets);

    vm.startPrank(USER);
    deal(address(usdc), USER, 1_000_000e6);
    usdc.approve(address(exaUSDC), type(uint256).max);
    uint256 actualRepayAssets = exaUSDC.repayAtMaturity(MATURITY, positionAssets, type(uint256).max, USER);

    assertEq(actualRepayAssets, repayAssets);
  }

  function test_fixedRepayAssets_maxUintAfterMaturity() external {
    uint256 positionAssets = type(uint256).max;
    skip(55 weeks);

    uint256 repayAssets = previewer.fixedRepayAssets(USER, exaUSDC, MATURITY, positionAssets);

    vm.startPrank(USER);
    deal(address(usdc), USER, 1_000_000e6);
    usdc.approve(address(exaUSDC), type(uint256).max);
    uint256 actualRepayAssets = exaUSDC.repayAtMaturity(MATURITY, positionAssets, type(uint256).max, USER);

    assertEq(actualRepayAssets, repayAssets);
  }

  function test_fixedRepayPosition_beforeMaturity() external {
    uint256 repayAssets = 420e6;

    uint256 positionAssets = previewer.fixedRepayPosition(USER, exaUSDC, MATURITY, repayAssets);

    vm.startPrank(USER);
    deal(address(usdc), USER, 1_000_000e6);
    usdc.approve(address(exaUSDC), type(uint256).max);
    uint256 actualRepayAssets = exaUSDC.repayAtMaturity(MATURITY, positionAssets, type(uint256).max, USER);

    assertLe(actualRepayAssets, repayAssets);
    assertApproxEqAbs(actualRepayAssets, repayAssets, 1);
  }

  function test_fixedRepayPosition_afterMaturity() external {
    uint256 repayAssets = 420e6;
    skip(55 weeks);

    uint256 positionAssets = previewer.fixedRepayPosition(USER, exaUSDC, MATURITY, repayAssets);

    vm.startPrank(USER);
    deal(address(usdc), USER, 1_000_000e6);
    usdc.approve(address(exaUSDC), type(uint256).max);
    uint256 actualRepayAssets = exaUSDC.repayAtMaturity(MATURITY, positionAssets, type(uint256).max, USER);

    assertLe(actualRepayAssets, repayAssets);
    assertApproxEqAbs(actualRepayAssets, repayAssets, 1);
  }

  function test_fixedRepayPosition_maxUint() external {
    uint256 repayAssets = type(uint256).max;
    (uint256 principal, uint256 fee) = exaUSDC.fixedBorrowPositions(MATURITY, USER);

    assertEq(previewer.fixedRepayPosition(USER, exaUSDC, MATURITY, repayAssets), principal + fee);

    skip(55 weeks);

    assertEq(previewer.fixedRepayPosition(USER, exaUSDC, MATURITY, repayAssets), principal + fee);
  }

  function test_fixedRepayPosition_saturatedFallback() external view {
    uint256 repayAssets = 13_859_081_618;
    (uint256 principal, uint256 fee) = exaUSDC.fixedBorrowPositions(MATURITY, USER);

    assertEq(previewer.fixedRepayPosition(USER, exaUSDC, MATURITY, repayAssets), principal + fee);
  }
  // #endregion

  // solhint-enable func-name-mixedcase
}
