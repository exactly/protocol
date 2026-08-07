// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17; // solhint-disable-line one-contract-per-file

import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import { ForkTest } from "./Fork.t.sol";
import { ERC20, FixedLib } from "../contracts/Market.sol";
import {
  Market,
  Auditor,
  IPriceFeed,
  RemainingDebt,
  AuditorMismatch,
  InvalidPriceFeed,
  MarketNotListed,
  MarketAlreadyListed,
  InsufficientShortfall,
  InsufficientAccountLiquidity
} from "../contracts/Auditor.sol";

contract AuditorTest is ForkTest {
  using FixedPointMathLib for uint256;

  address internal constant BOB = address(0x420);

  Auditor internal auditor;
  MockMarket internal market;
  IPriceFeed internal priceFeed;

  address internal timelock;
  Market[] internal liveMarkets;
  MarketState[] internal states;
  uint256 internal liquidatorIncentive;
  uint256 internal lendersIncentive;

  struct MarketState {
    uint128 adjustFactor;
    uint8 decimals;
    uint8 index;
    bool isListed;
    IPriceFeed priceFeed;
    uint256 totalAssets;
    uint256 totalSupply;
    uint256 totalFloatingBorrowAssets;
  }

  event MarketListed(Market indexed market, uint8 decimals);
  event MarketEntered(Market indexed market, address indexed account);
  event MarketExited(Market indexed market, address indexed account);
  event NonCollateralSet(Market indexed market, bool disabled);

  function setUp() external {
    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    vm.label(address(auditor), "Auditor");
    market = new MockMarket(auditor, 18);
    priceFeed = new MockPriceFeed(18, 1e18);
    vm.label(BOB, "bob");
  }

  modifier whenUpgraded() {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 155_130_000);
    auditor = Auditor(deployment("Auditor"));
    timelock = deployment("TimelockController");

    Market[] memory allMarkets = auditor.allMarkets();
    for (uint256 i = 0; i < allMarkets.length; ++i) {
      Market m = allMarkets[i];
      liveMarkets.push(m);
      // the deployed auditor still has the 5-field getter, so state is captured through the legacy ABI
      (uint128 adjustFactor, uint8 decimals, uint8 index, bool isListed, IPriceFeed feed) = ILegacyAuditor(
        address(auditor)
      ).markets(m);
      states.push(
        MarketState({
          adjustFactor: adjustFactor,
          decimals: decimals,
          index: index,
          isListed: isListed,
          priceFeed: feed,
          totalAssets: m.totalAssets(),
          totalSupply: m.totalSupply(),
          totalFloatingBorrowAssets: m.totalFloatingBorrowAssets()
        })
      );
    }
    (liquidatorIncentive, lendersIncentive) = auditor.liquidationIncentive();

    upgrade(address(auditor), address(new Auditor(auditor.priceDecimals())));
    _;
  }

  function testEnableMarket() external {
    vm.expectEmit(true, true, true, true, address(auditor));
    emit MarketListed(Market(address(market)), 18);

    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);

    (
      uint256 adjustFactor,
      uint8 decimals,
      uint8 index,
      bool isListed,
      IPriceFeed oraclePriceFeed,
      bool nonCollateral
    ) = auditor.markets(Market(address(market)));
    Market[] memory markets = auditor.allMarkets();
    assertTrue(isListed);
    assertFalse(nonCollateral);
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
    auditor.enableMarket(Market(address(market)), invalidPriceFeed, 0.8e18, false);
  }

  function testEnterExitMarket() external {
    market.setCollateral(1 ether);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);

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
      auditor.enableMarket(markets[i], priceFeed, 0.8e18, false);
      auditor.enterMarket(markets[i]);
    }

    for (uint8 i = 0; i < markets.length; i++) {
      vm.expectEmit(true, false, false, true, address(auditor));
      emit MarketExited(markets[i], address(this));
      auditor.exitMarket(markets[i]);
    }
  }

  function testExitMarketOwning() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    auditor.enterMarket(Market(address(market)));
    market.setDebt(1);
    vm.expectRevert(RemainingDebt.selector);
    auditor.exitMarket(Market(address(market)));
  }

  function testEnableMarketAlreadyListed() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    vm.expectRevert(MarketAlreadyListed.selector);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
  }

  function testEnableMarketAuditorMismatch() external {
    market.setAuditor(address(0));
    vm.expectRevert(AuditorMismatch.selector);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
  }

  function testEnableMarketNonCollateral() external {
    vm.expectEmit(true, true, true, true, address(auditor));
    emit NonCollateralSet(Market(address(market)), true);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, true);

    (, , uint256 index, , , bool nonCollateral) = auditor.markets(Market(address(market)));
    assertTrue(nonCollateral);
    auditor.enterMarket(Market(address(market)));
    assertEq(auditor.accountMarkets(address(this)) & (1 << index), 1 << index);
  }

  function testSetNonCollateral() external {
    market.setCollateral(1 ether);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    auditor.enterMarket(Market(address(market)));

    vm.expectEmit(true, true, true, true, address(auditor));
    emit NonCollateralSet(Market(address(market)), true);
    auditor.setNonCollateral(Market(address(market)), true);
    (, , , , , bool nonCollateral) = auditor.markets(Market(address(market)));
    assertTrue(nonCollateral);
    (uint256 collateral, ) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(collateral, 0);

    vm.expectEmit(true, true, true, true, address(auditor));
    emit NonCollateralSet(Market(address(market)), false);
    auditor.setNonCollateral(Market(address(market)), false);
    (, , , , , nonCollateral) = auditor.markets(Market(address(market)));
    assertFalse(nonCollateral);
    (collateral, ) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(collateral, uint256(1 ether).mulWadDown(0.8e18));
  }

  function testSetNonCollateralNotListed() external {
    vm.expectRevert(MarketNotListed.selector);
    auditor.setNonCollateral(Market(address(market)), true);
  }

  function testBorrowMPValidation() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    auditor.enterMarket(Market(address(market)));
    auditor.checkBorrow(Market(address(market)), address(this));
  }

  function testBorrowMPValidationRevert() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    auditor.enterMarket(Market(address(market)));
    market.setDebt(1);
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    auditor.checkBorrow(Market(address(market)), address(this));
  }

  function testAccountShortfall() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    auditor.enterMarket(Market(address(market)));
    auditor.checkShortfall(Market(address(market)), address(this), 1);
  }

  function testAccountShortfallRevert() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    auditor.enterMarket(Market(address(market)));
    market.setDebt(1);
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    auditor.checkShortfall(Market(address(market)), address(this), 1);
  }

  function testDynamicCloseFactor() external {
    Market[] memory markets = new Market[](4);
    for (uint8 i = 0; i < markets.length; i++) {
      markets[i] = Market(address(new MockMarket(auditor, 18 - (i * 3))));
      auditor.enableMarket(markets[i], priceFeed, 0.9e18 - (i * 0.1e18), false);

      vm.prank(BOB);
      auditor.enterMarket(markets[i]);
    }

    MockMarket(address(markets[1])).setDebt(200e15);
    MockMarket(address(markets[3])).setCollateral(1e9);
    auditor.checkLiquidation(markets[1], markets[3], BOB, type(uint256).max);
  }

  function testSetNonCollateralOnlyAdmin() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    vm.prank(BOB);
    vm.expectRevert(bytes(""));
    auditor.setNonCollateral(Market(address(market)), true);
  }

  function testEnableSecondMarketNonCollateral() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    MockMarket secondMarket = new MockMarket(auditor, 18);
    auditor.enableMarket(Market(address(secondMarket)), priceFeed, 0.8e18, true);
    (, , , , , bool firstDisabled) = auditor.markets(Market(address(market)));
    (, , , , , bool secondDisabled) = auditor.markets(Market(address(secondMarket)));
    assertFalse(firstDisabled);
    assertTrue(secondDisabled);

    auditor.enterMarket(Market(address(market)));
    auditor.enterMarket(Market(address(secondMarket)));
    assertEq(auditor.accountMarkets(address(this)), 3);
  }

  function testCheckShortfallBypassesNonCollateralMarket() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    auditor.enterMarket(Market(address(market)));
    market.setCollateral(1 ether);
    market.setDebt(1 ether);

    vm.expectRevert(InsufficientAccountLiquidity.selector);
    auditor.checkShortfall(Market(address(market)), address(this), 1);

    auditor.setNonCollateral(Market(address(market)), true);
    auditor.checkShortfall(Market(address(market)), address(this), 1);
  }

  function testAccountLiquiditySkipsWithdrawSimulationOfNonCollateralMarket() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    auditor.enterMarket(Market(address(market)));
    market.setCollateral(1 ether);

    (uint256 collateral, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(market)), 0.5 ether);
    assertEq(collateral, uint256(1 ether).mulWadDown(0.8e18));
    assertEq(debt, uint256(0.5 ether).mulWadDown(0.8e18));

    auditor.setNonCollateral(Market(address(market)), true);
    (collateral, debt) = auditor.accountLiquidity(address(this), Market(address(market)), 0.5 ether);
    assertEq(collateral, 0);
    assertEq(debt, 0);
  }

  function testExitNonCollateralMarketWithShortfall() external {
    MockMarket debtMarket = new MockMarket(auditor, 18);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    auditor.enableMarket(Market(address(debtMarket)), priceFeed, 0.8e18, false);
    auditor.enterMarket(Market(address(market)));
    auditor.enterMarket(Market(address(debtMarket)));
    market.setCollateral(1 ether);
    debtMarket.setDebt(0.5 ether);

    vm.expectRevert(InsufficientAccountLiquidity.selector);
    auditor.exitMarket(Market(address(market)));

    auditor.setNonCollateral(Market(address(market)), true);
    auditor.exitMarket(Market(address(market)));
    assertEq(auditor.accountMarkets(address(this)) & 1, 0);
  }

  function testCheckLiquidationSkipsNonCollateralMarkets() external {
    MockMarket debtMarket = new MockMarket(auditor, 18);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    auditor.enableMarket(Market(address(debtMarket)), priceFeed, 0.8e18, false);
    auditor.enterMarket(Market(address(market)));
    auditor.enterMarket(Market(address(debtMarket)));
    market.setCollateral(1 ether);
    debtMarket.setDebt(0.5 ether);

    // account is healthy while the collateral is eligible
    vm.expectRevert(InsufficientShortfall.selector);
    auditor.checkLiquidation(Market(address(debtMarket)), Market(address(market)), address(this), type(uint256).max);

    // with its only collateral disabled the account has no total collateral and can't be liquidated
    auditor.setNonCollateral(Market(address(market)), true);
    vm.expectRevert(bytes(""));
    auditor.checkLiquidation(Market(address(debtMarket)), Market(address(market)), address(this), type(uint256).max);
  }

  function testCheckLiquidationZeroRepayForNonCollateralSeizeMarket() external {
    MockMarket seizeMarket = new MockMarket(auditor, 18);
    MockMarket debtMarket = new MockMarket(auditor, 18);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    auditor.enableMarket(Market(address(seizeMarket)), priceFeed, 0.8e18, false);
    auditor.enableMarket(Market(address(debtMarket)), priceFeed, 0.8e18, false);
    auditor.enterMarket(Market(address(market)));
    auditor.enterMarket(Market(address(seizeMarket)));
    auditor.enterMarket(Market(address(debtMarket)));
    market.setCollateral(0.1 ether);
    seizeMarket.setCollateral(1 ether);
    debtMarket.setDebt(1 ether);

    auditor.setNonCollateral(Market(address(seizeMarket)), true);

    // shortfall exists but nothing can be seized from the disabled market
    uint256 maxRepay = auditor.checkLiquidation(
      Market(address(debtMarket)),
      Market(address(seizeMarket)),
      address(this),
      type(uint256).max
    );
    assertEq(maxRepay, 0);

    // seizing from the enabled market is still allowed
    maxRepay = auditor.checkLiquidation(
      Market(address(debtMarket)),
      Market(address(market)),
      address(this),
      type(uint256).max
    );
    assertGt(maxRepay, 0);
  }

  function testHandleBadDebtIgnoresNonCollateralMarkets() external {
    MockMarket debtMarket = new MockMarket(auditor, 18);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, false);
    auditor.enableMarket(Market(address(debtMarket)), priceFeed, 0.8e18, false);
    auditor.enterMarket(Market(address(market)));
    auditor.enterMarket(Market(address(debtMarket)));
    market.setCollateral(1 ether);
    debtMarket.setDebt(1 ether);

    // positive eligible collateral blocks bad debt clearing
    auditor.handleBadDebt(address(this));
    assertEq(debtMarket.clearBadDebtCalls(), 0);

    // once disabled as collateral, the supply no longer blocks and is not consumed by the clearing
    auditor.setNonCollateral(Market(address(market)), true);
    auditor.handleBadDebt(address(this));
    assertEq(debtMarket.clearBadDebtCalls(), 1);
    assertEq(market.clearBadDebtCalls(), 1);
    (uint256 collateral, ) = market.accountSnapshot(address(this));
    assertEq(collateral, 1 ether);
  }

  function testUpgradePreservesState() external whenUpgraded {
    Market[] memory allMarkets = auditor.allMarkets();
    assertEq(allMarkets.length, liveMarkets.length);
    (uint256 liquidator, uint256 lenders) = auditor.liquidationIncentive();
    assertEq(liquidator, liquidatorIncentive);
    assertEq(lenders, lendersIncentive);

    for (uint256 i = 0; i < liveMarkets.length; ++i) {
      assertEq(address(allMarkets[i]), address(liveMarkets[i]));
      (uint128 adjustFactor, uint8 decimals, uint8 index, bool isListed, IPriceFeed feed, bool nonCollateral) = auditor
        .markets(liveMarkets[i]);
      assertEq(adjustFactor, states[i].adjustFactor);
      assertEq(decimals, states[i].decimals);
      assertEq(index, states[i].index);
      assertTrue(isListed);
      assertEq(address(feed), address(states[i].priceFeed));
      assertFalse(nonCollateral);
      assertEq(liveMarkets[i].totalAssets(), states[i].totalAssets);
      assertEq(liveMarkets[i].totalSupply(), states[i].totalSupply);
      assertEq(liveMarkets[i].totalFloatingBorrowAssets(), states[i].totalFloatingBorrowAssets);
    }
  }

  function testLegacyMarketsGetterAfterUpgrade() external whenUpgraded {
    // integrators compiled before `nonCollateral` was appended keep decoding the getter
    for (uint256 i = 0; i < liveMarkets.length; ++i) {
      (uint128 adjustFactor, uint8 decimals, uint8 index, bool isListed, IPriceFeed feed) = ILegacyAuditor(
        address(auditor)
      ).markets(liveMarkets[i]);
      assertEq(adjustFactor, states[i].adjustFactor);
      assertEq(decimals, states[i].decimals);
      assertEq(index, states[i].index);
      assertTrue(isListed);
      assertEq(address(feed), address(states[i].priceFeed));
    }
  }

  function testMarketsOperateAfterUpgrade() external whenUpgraded {
    for (uint256 i = 0; i < liveMarkets.length; ++i) {
      Market m = liveMarkets[i];
      if (m.isFrozen()) continue; // exaUSDC.e is frozen at the pinned block

      ERC20 asset = m.asset();
      uint256 baseUnit = 10 ** states[i].decimals;
      address account = makeAddr(string.concat("account", vm.toString(i)));
      deal(address(asset), account, 2_000 * baseUnit);

      vm.startPrank(account);
      asset.approve(address(m), type(uint256).max);
      m.deposit(1_000 * baseUnit, account);
      auditor.enterMarket(m);
      // let `floatingAssetsAverage` catch up with the deposit so fixed rates stay sane
      vm.warp(block.timestamp + 1 hours);
      uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;

      (uint256 collateral, uint256 debt) = auditor.accountLiquidity(account, Market(address(0)), 0);
      assertGt(collateral, 0, "deposit not counted as collateral");
      assertEq(debt, 0, "debt before borrowing");

      uint256 adjustFactor = states[i].adjustFactor;
      uint256 borrowAssets = (1_000 * baseUnit).mulWadDown(adjustFactor).mulWadDown(adjustFactor) / 4;
      m.borrow(borrowAssets, account, account);
      m.borrowAtMaturity(maturity, borrowAssets, type(uint256).max, account, account);
      (, debt) = auditor.accountLiquidity(account, Market(address(0)), 0);
      assertGt(debt, 0, "debt after borrowing");

      (uint256 principal, uint256 fee) = m.fixedBorrowPositions(maturity, account);
      deal(address(asset), account, asset.balanceOf(account) + principal + fee);
      (, , uint256 floatingBorrowShares) = m.accounts(account);
      m.refund(floatingBorrowShares, account);
      m.repayAtMaturity(maturity, type(uint256).max, type(uint256).max, account);
      m.redeem(m.balanceOf(account), account, account);
      auditor.exitMarket(m);
      vm.stopPrank();

      (collateral, debt) = auditor.accountLiquidity(account, Market(address(0)), 0);
      assertEq(collateral, 0, "collateral after exiting");
      assertEq(debt, 0, "debt after repaying");
      assertEq(m.balanceOf(account), 0, "shares after redeeming");
    }
  }

  function testSetNonCollateralAfterUpgrade() external whenUpgraded {
    Market m = liveMarkets[0]; // exaWETH
    uint256 baseUnit = 10 ** states[0].decimals;
    address account = makeAddr("depositor");
    deal(address(m.asset()), account, 1_000 * baseUnit);

    vm.startPrank(account);
    m.asset().approve(address(m), type(uint256).max);
    m.deposit(1_000 * baseUnit, account);
    auditor.enterMarket(m);
    vm.stopPrank();

    (uint256 collateral, ) = auditor.accountLiquidity(account, Market(address(0)), 0);
    assertGt(collateral, 0, "deposit not counted as collateral");

    vm.prank(timelock);
    auditor.setNonCollateral(m, true);
    (, , , , , bool nonCollateral) = auditor.markets(m);
    assertTrue(nonCollateral);

    (collateral, ) = auditor.accountLiquidity(account, Market(address(0)), 0);
    assertEq(collateral, 0, "non-collateral market still counted as collateral");

    // supply stays freely withdrawable while the account is still in the market
    vm.startPrank(account);
    m.redeem(m.balanceOf(account) / 2, account, account);
    vm.stopPrank();

    vm.prank(timelock);
    auditor.setNonCollateral(m, false);
    (, , , , , nonCollateral) = auditor.markets(m);
    assertFalse(nonCollateral);
    (collateral, ) = auditor.accountLiquidity(account, Market(address(0)), 0);
    assertGt(collateral, 0, "restored market not counted as collateral");
  }

  function testBorrowFromNonCollateralMarketAfterUpgrade() external whenUpgraded {
    Market collateralMarket = liveMarkets[0]; // exaWETH
    Market borrowMarket = liveMarkets[2]; // exaOP

    vm.prank(timelock);
    auditor.setNonCollateral(borrowMarket, true);

    address account = makeAddr("borrower");
    deal(address(collateralMarket.asset()), account, 1_000 * 10 ** states[0].decimals);
    deal(address(borrowMarket.asset()), account, 10 * 10 ** states[2].decimals);

    vm.startPrank(account);
    collateralMarket.asset().approve(address(collateralMarket), type(uint256).max);
    collateralMarket.deposit(1_000 * 10 ** states[0].decimals, account);
    auditor.enterMarket(collateralMarket);
    (uint256 collateral, ) = auditor.accountLiquidity(account, Market(address(0)), 0);

    // depositing in the non-collateral market adds no borrowing power
    borrowMarket.asset().approve(address(borrowMarket), type(uint256).max);
    borrowMarket.deposit(10 * 10 ** states[2].decimals, account);
    (uint256 newCollateral, ) = auditor.accountLiquidity(account, Market(address(0)), 0);
    assertEq(newCollateral, collateral, "non-collateral market deposit added borrowing power");

    // the non-collateral market stays fully borrowable against regular collateral
    uint256 borrowAssets = collateral.mulWadDown(states[2].adjustFactor).mulDivDown(
      10 ** states[2].decimals,
      auditor.assetPrice(states[2].priceFeed)
    ) / 2;
    if (borrowAssets > borrowMarket.totalAssets() / 10) borrowAssets = borrowMarket.totalAssets() / 10;
    borrowMarket.borrow(borrowAssets, account, account);
    vm.stopPrank();

    assertNotEq(auditor.accountMarkets(account) & (1 << states[2].index), 0, "borrow did not auto-enter the market");
    (, uint256 debt) = auditor.accountLiquidity(account, Market(address(0)), 0);
    assertGt(debt, 0, "borrowed debt not accounted");
  }
}

contract MockMarket {
  Auditor public auditor;
  uint256 internal collateral;
  uint256 internal debt;
  uint256 public clearBadDebtCalls;
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

  function accountSnapshot(address) external view returns (uint256, uint256) {
    return (collateral, debt);
  }

  function maxWithdraw(address) external view returns (uint256) {
    return collateral;
  }

  function clearBadDebt(address) external {
    debt = 0;
    ++clearBadDebtCalls;
  }
}

/// @dev The `markets` getter as integrators compiled before `MarketData.nonCollateral` was appended see it.
interface ILegacyAuditor {
  function markets(Market market) external view returns (uint128, uint8, uint8, bool, IPriceFeed);
}
