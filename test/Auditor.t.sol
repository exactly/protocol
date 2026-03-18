// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17; // solhint-disable-line one-contract-per-file

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import {
  Market,
  Auditor,
  IPriceFeed,
  RemainingDebt,
  AuditorMismatch,
  InvalidPriceFeed,
  MarketNotListed,
  MarketAlreadyListed,
  InsufficientAccountLiquidity
} from "../contracts/Auditor.sol";

contract AuditorTest is Test {
  using FixedPointMathLib for uint256;

  address internal constant BOB = address(0x420);

  Auditor internal auditor;
  MockMarket internal market;
  IPriceFeed internal priceFeed;

  event MarketListed(Market indexed market, uint8 decimals);
  event MarketEntered(Market indexed market, address indexed account);
  event MarketExited(Market indexed market, address indexed account);

  function setUp() external {
    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    vm.label(address(auditor), "Auditor");
    market = new MockMarket(auditor, 18);
    priceFeed = new MockPriceFeed(18, 1e18);
    vm.label(BOB, "bob");
  }

  function testEnableMarket() external {
    vm.expectEmit(true, true, true, true, address(auditor));
    emit MarketListed(Market(address(market)), 18);

    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);

    (uint256 adjustFactor, uint8 decimals, uint8 index, bool isListed, IPriceFeed oraclePriceFeed) = auditor.markets(
      Market(address(market))
    );
    Market[] memory markets = auditor.allMarkets();
    assertTrue(isListed);
    assertEq(address(oraclePriceFeed), address(priceFeed));
    assertEq(index, 0);
    assertEq(decimals, 18);
    assertEq(adjustFactor, 0.8e18);
    assertEq(markets.length, 1);
    assertEq(address(markets[0]), address(market));
  }

  function testEnableMarketShouldRevertWithInvalidPriceFeed() external {
    MockPriceFeed invalidPriceFeed = new MockPriceFeed(8, 1e8);
    vm.expectRevert(InvalidPriceFeed.selector);
    auditor.enableMarket(Market(address(market)), invalidPriceFeed, 0.8e18);
  }

  function testEnterExitMarket() external {
    market.setCollateral(1 ether);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);

    vm.expectEmit(true, false, false, true, address(auditor));
    emit MarketEntered(Market(address(market)), address(this));
    auditor.enterMarket(Market(address(market)));
    (uint256 collateral, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(collateral, uint256(1 ether).mulWadDown(0.8e18));
    assertEq(debt, 0);

    vm.expectEmit(true, false, false, true, address(auditor));
    emit MarketExited(Market(address(market)), address(this));
    auditor.exitMarket(Market(address(market)));
    (collateral, debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(collateral, 0);
    assertEq(debt, 0);
  }

  function testEnableEnterExitMultipleMarkets() external {
    Market[] memory markets = new Market[](4);
    for (uint8 i = 0; i < markets.length; i++) {
      markets[i] = Market(address(new MockMarket(auditor, 18)));
      auditor.enableMarket(markets[i], priceFeed, 0.8e18);
      auditor.enterMarket(markets[i]);
    }

    for (uint8 i = 0; i < markets.length; i++) {
      vm.expectEmit(true, false, false, true, address(auditor));
      emit MarketExited(markets[i], address(this));
      auditor.exitMarket(markets[i]);
    }
  }

  function testExitMarketOwning() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);
    auditor.enterMarket(Market(address(market)));
    market.setDebt(1);
    vm.expectRevert(RemainingDebt.selector);
    auditor.exitMarket(Market(address(market)));
  }

  function testEnableMarketAlreadyListed() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);
    vm.expectRevert(MarketAlreadyListed.selector);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);
  }

  function testEnableMarketAuditorMismatch() external {
    market.setAuditor(address(0));
    vm.expectRevert(AuditorMismatch.selector);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);
  }

  function testBorrowMPValidation() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);
    auditor.enterMarket(Market(address(market)));
    auditor.checkBorrow(Market(address(market)), address(this));
  }

  function testBorrowMPValidationRevert() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);
    auditor.enterMarket(Market(address(market)));
    market.setDebt(1);
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    auditor.checkBorrow(Market(address(market)), address(this));
  }

  function testAccountShortfall() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);
    auditor.enterMarket(Market(address(market)));
    auditor.checkShortfall(Market(address(market)), address(this), 1);
  }

  function testAccountShortfallRevert() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);
    auditor.enterMarket(Market(address(market)));
    market.setDebt(1);
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    auditor.checkShortfall(Market(address(market)), address(this), 1);
  }

  function testDynamicCloseFactor() external {
    Market[] memory markets = new Market[](4);
    for (uint8 i = 0; i < markets.length; i++) {
      markets[i] = Market(address(new MockMarket(auditor, 18 - (i * 3))));
      auditor.enableMarket(markets[i], priceFeed, 0.9e18 - (i * 0.1e18));

      vm.prank(BOB);
      auditor.enterMarket(markets[i]);
    }

    MockMarket(address(markets[1])).setDebt(200e15);
    MockMarket(address(markets[3])).setCollateral(1e9);
    auditor.checkLiquidation(markets[1], markets[3], BOB, type(uint256).max);
  }

  function test_setLiquidationIncentive_setsAndEmits() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);
    Auditor.LiquidationIncentive memory incentive = Auditor.LiquidationIncentive(0.15e18, 0.02e18);

    vm.expectEmit(true, true, true, true, address(auditor));
    emit LiquidationIncentiveSet(Market(address(market)), incentive);
    auditor.setLiquidationIncentive(Market(address(market)), incentive);

    (uint128 liquidator, uint128 lenders) = auditor.marketLiquidationIncentive(Market(address(market)));
    assertEq(liquidator, 0.15e18);
    assertEq(lenders, 0.02e18);
  }

  function test_setLiquidationIncentive_reverts_whenMarketNotListed() external {
    vm.expectRevert(MarketNotListed.selector);
    auditor.setLiquidationIncentive(Market(address(market)), Auditor.LiquidationIncentive(0.15e18, 0.02e18));
  }

  function test_getLiquidationIncentive_returnsGlobal_whenPerMarketUnset() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18);
    Auditor.LiquidationIncentive memory incentive = auditor.getLiquidationIncentive(Market(address(market)));
    assertEq(incentive.liquidator, 0.09e18);
    assertEq(incentive.lenders, 0.01e18);
  }

  function test_calculateSeize_usesSeizeMarketIncentive() external {
    MockMarket repayMkt = new MockMarket(auditor, 18);
    MockMarket seizeMkt = new MockMarket(auditor, 18);
    auditor.enableMarket(Market(address(repayMkt)), priceFeed, 0.8e18);
    auditor.enableMarket(Market(address(seizeMkt)), priceFeed, 0.8e18);

    auditor.setLiquidationIncentive(Market(address(seizeMkt)), Auditor.LiquidationIncentive(0.15e18, 0.02e18));

    vm.startPrank(BOB);
    auditor.enterMarket(Market(address(repayMkt)));
    auditor.enterMarket(Market(address(seizeMkt)));
    vm.stopPrank();

    repayMkt.setDebt(1 ether);
    seizeMkt.setCollateral(2 ether);
    seizeMkt.setMaxWithdraw(2 ether);

    (uint256 lendersAssets, uint256 seizeAssets) = auditor.calculateSeize(
      Market(address(repayMkt)),
      Market(address(seizeMkt)),
      BOB,
      1 ether
    );
    assertEq(lendersAssets, 0.02e18);
    assertEq(seizeAssets, 1.17e18);
  }

  function test_calculateSeize_ignoresRepayMarketIncentive() external {
    MockMarket repayMkt = new MockMarket(auditor, 18);
    MockMarket seizeMkt = new MockMarket(auditor, 18);
    auditor.enableMarket(Market(address(repayMkt)), priceFeed, 0.8e18);
    auditor.enableMarket(Market(address(seizeMkt)), priceFeed, 0.8e18);

    // per-market incentive on the REPAY market — should be ignored
    auditor.setLiquidationIncentive(Market(address(repayMkt)), Auditor.LiquidationIncentive(0.20e18, 0.05e18));

    vm.startPrank(BOB);
    auditor.enterMarket(Market(address(repayMkt)));
    auditor.enterMarket(Market(address(seizeMkt)));
    vm.stopPrank();

    repayMkt.setDebt(1 ether);
    seizeMkt.setCollateral(2 ether);
    seizeMkt.setMaxWithdraw(2 ether);

    (uint256 lendersAssets, uint256 seizeAssets) = auditor.calculateSeize(
      Market(address(repayMkt)),
      Market(address(seizeMkt)),
      BOB,
      1 ether
    );
    // seize market has no per-market incentive → falls back to global (0.09 + 0.01)
    assertEq(lendersAssets, 0.01e18);
    assertEq(seizeAssets, 1.1e18);
  }

  event LiquidationIncentiveSet(Market indexed market, Auditor.LiquidationIncentive liquidationIncentive);
}

contract MockMarket {
  Auditor public auditor;
  uint256 internal collateral;
  uint256 internal debt;
  uint256 internal _maxWithdraw;
  uint8 public immutable decimals;

  constructor(Auditor auditor_, uint8 decimals_) {
    auditor = auditor_;
    decimals = decimals_;
  }

  function setAuditor(address auditor_) external {
    auditor = Auditor(auditor_);
  }

  function setCollateral(uint256 collateral_) external {
    collateral = collateral_;
  }

  function setDebt(uint256 debt_) external {
    debt = debt_;
  }

  function setMaxWithdraw(uint256 maxWithdraw_) external {
    _maxWithdraw = maxWithdraw_;
  }

  function accountSnapshot(address) external view returns (uint256, uint256) {
    return (collateral, debt);
  }

  function maxWithdraw(address) external view returns (uint256) {
    return _maxWithdraw;
  }
}
