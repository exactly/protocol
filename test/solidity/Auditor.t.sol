// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MockPriceFeed } from "../../contracts/mocks/MockPriceFeed.sol";
import {
  Market,
  Auditor,
  IPriceFeed,
  RemainingDebt,
  AuditorMismatch,
  InvalidPriceFeed,
  MarketAlreadyListed,
  InsufficientAccountLiquidity
} from "../../contracts/Auditor.sol";

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
    market = new MockMarket(auditor);
    priceFeed = new MockPriceFeed(18, 1e18);
    vm.label(BOB, "bob");
  }

  function testEnableMarket() external {
    vm.expectEmit(true, true, true, true, address(auditor));
    emit MarketListed(Market(address(market)), 18);

    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, 18);

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
    auditor.enableMarket(Market(address(market)), invalidPriceFeed, 0.8e18, 18);
  }

  function testEnterExitMarket() external {
    market.setCollateral(1 ether);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, 18);

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
      markets[i] = Market(address(new MockMarket(auditor)));
      auditor.enableMarket(markets[i], priceFeed, 0.8e18, 18);
      auditor.enterMarket(markets[i]);
    }

    for (uint8 i = 0; i < markets.length; i++) {
      vm.expectEmit(true, false, false, true, address(auditor));
      emit MarketExited(markets[i], address(this));
      auditor.exitMarket(markets[i]);
    }
  }

  function testExitMarketOwning() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, 18);
    auditor.enterMarket(Market(address(market)));
    market.setDebt(1);
    vm.expectRevert(RemainingDebt.selector);
    auditor.exitMarket(Market(address(market)));
  }

  function testEnableMarketAlreadyListed() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, 18);
    vm.expectRevert(MarketAlreadyListed.selector);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, 18);
  }

  function testEnableMarketAuditorMismatch() external {
    market.setAuditor(address(0));
    vm.expectRevert(AuditorMismatch.selector);
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, 18);
  }

  function testBorrowMPValidation() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, 18);
    auditor.enterMarket(Market(address(market)));
    auditor.checkBorrow(Market(address(market)), address(this));
  }

  function testBorrowMPValidationRevert() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, 18);
    auditor.enterMarket(Market(address(market)));
    market.setDebt(1);
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    auditor.checkBorrow(Market(address(market)), address(this));
  }

  function testAccountShortfall() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, 18);
    auditor.enterMarket(Market(address(market)));
    auditor.checkShortfall(Market(address(market)), address(this), 1);
  }

  function testAccountShortfallRevert() external {
    auditor.enableMarket(Market(address(market)), priceFeed, 0.8e18, 18);
    auditor.enterMarket(Market(address(market)));
    market.setDebt(1);
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    auditor.checkShortfall(Market(address(market)), address(this), 1);
  }

  function testDynamicCloseFactor() external {
    Market[] memory markets = new Market[](4);
    for (uint8 i = 0; i < markets.length; i++) {
      markets[i] = Market(address(new MockMarket(auditor)));
      auditor.enableMarket(markets[i], priceFeed, 0.9e18 - (i * 0.1e18), 18 - (i * 3));

      vm.prank(BOB);
      auditor.enterMarket(markets[i]);
    }

    MockMarket(address(markets[1])).setDebt(200e15);
    MockMarket(address(markets[3])).setCollateral(1e9);
    auditor.checkLiquidation(markets[1], markets[3], BOB, type(uint256).max);
  }
}

contract MockMarket {
  Auditor public auditor;
  uint256 internal collateral;
  uint256 internal debt;

  constructor(Auditor auditor_) {
    auditor = auditor_;
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
}
