// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { Auditor, FixedLender, ExactlyOracle } from "../../contracts/Auditor.sol";

contract AuditorTest is Test {
  using FixedPointMathLib for uint256;

  address internal constant BOB = address(0x420);

  Auditor internal auditor;
  MockOracle internal oracle;
  MockFixedLender internal fixedLender;

  event MarketListed(FixedLender fixedLender, uint8 decimals);
  event MarketEntered(FixedLender indexed fixedLender, address indexed account);
  event MarketExited(FixedLender indexed fixedLender, address indexed account);

  function setUp() external {
    oracle = new MockOracle();
    auditor = new Auditor(ExactlyOracle(address(oracle)), Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    fixedLender = new MockFixedLender(auditor);
    vm.label(BOB, "bob");
  }

  function testEnableMarket() external {
    vm.expectEmit(false, false, false, true, address(auditor));
    emit MarketListed(FixedLender(address(fixedLender)), 18);

    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, 18);

    (uint256 adjustFactor, uint8 decimals, uint8 index, bool isListed) = auditor.markets(
      FixedLender(address(fixedLender))
    );
    FixedLender[] memory markets = auditor.getAllMarkets();
    assertTrue(isListed);
    assertEq(index, 0);
    assertEq(decimals, 18);
    assertEq(adjustFactor, 0.8e18);
    assertEq(markets.length, 1);
    assertEq(address(markets[0]), address(fixedLender));
  }

  function testEnterExitMarket() external {
    fixedLender.setCollateral(1 ether);
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, 18);

    vm.expectEmit(true, false, false, true, address(auditor));
    emit MarketEntered(FixedLender(address(fixedLender)), address(this));
    auditor.enterMarket(FixedLender(address(fixedLender)));
    (uint256 collateral, uint256 debt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    assertEq(collateral, uint256(1 ether).mulWadDown(0.8e18));
    assertEq(debt, 0);

    vm.expectEmit(true, false, false, true, address(auditor));
    emit MarketExited(FixedLender(address(fixedLender)), address(this));
    auditor.exitMarket(FixedLender(address(fixedLender)));
    (collateral, debt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    assertEq(collateral, 0);
    assertEq(debt, 0);
  }

  function testEnableEnterExitMultipleMarkets() external {
    FixedLender[] memory markets = new FixedLender[](4);
    for (uint8 i = 0; i < markets.length; i++) {
      markets[i] = FixedLender(address(new MockFixedLender(auditor)));
      auditor.enableMarket(markets[i], 0.8e18, 18);
      auditor.enterMarket(markets[i]);
    }

    for (uint8 i = 0; i < markets.length; i++) {
      vm.expectEmit(true, false, false, true, address(auditor));
      emit MarketExited(markets[i], address(this));
      auditor.exitMarket(markets[i]);
    }
  }

  function testFailExitMarketOwning() external {
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, 18);
    auditor.enterMarket(FixedLender(address(fixedLender)));
    fixedLender.setDebt(1);
    auditor.exitMarket(FixedLender(address(fixedLender)));
  }

  function testFailEnableMarketAlreadyListed() external {
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, 18);
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, 18);
  }

  function testFailEnableMarketAuditorMismatch() external {
    fixedLender.setAuditor(address(0));
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, 18);
  }

  function testBorrowMPValidation() external {
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, 18);
    auditor.enterMarket(FixedLender(address(fixedLender)));
    auditor.validateBorrow(FixedLender(address(fixedLender)), address(this));
  }

  function testFailBorrowMPValidation() external {
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, 18);
    auditor.enterMarket(FixedLender(address(fixedLender)));
    fixedLender.setDebt(1);
    auditor.validateBorrow(FixedLender(address(fixedLender)), address(this));
  }

  function testAccountShortfall() external {
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, 18);
    auditor.enterMarket(FixedLender(address(fixedLender)));
    auditor.validateAccountShortfall(FixedLender(address(fixedLender)), address(this), 1);
  }

  function testFailAccountShortfall() external {
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, 18);
    auditor.enterMarket(FixedLender(address(fixedLender)));
    fixedLender.setDebt(1);
    auditor.validateAccountShortfall(FixedLender(address(fixedLender)), address(this), 1);
  }

  function testDynamicCloseFactor() external {
    FixedLender[] memory markets = new FixedLender[](4);
    for (uint8 i = 0; i < markets.length; i++) {
      markets[i] = FixedLender(address(new MockFixedLender(auditor)));
      auditor.enableMarket(markets[i], 0.9e18 - (i * 0.1e18), 18 - (i * 3));

      if (i % 2 != 0) oracle.setPrice(markets[i], i * 10**(i + 18));

      vm.prank(BOB);
      auditor.enterMarket(markets[i]);
    }

    MockFixedLender(address(markets[1])).setDebt(200e15);
    MockFixedLender(address(markets[3])).setCollateral(1e9);
    auditor.checkLiquidation(markets[1], markets[3], address(this), BOB);
  }
}

contract MockFixedLender {
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

  function getAccountSnapshot(address) external view returns (uint256, uint256) {
    return (collateral, debt);
  }
}

contract MockOracle {
  mapping(FixedLender => uint256) public prices;

  function setPrice(FixedLender market, uint256 value) public {
    prices[market] = value;
  }

  function getAssetPrice(FixedLender market) public view returns (uint256) {
    return prices[market] > 0 ? prices[market] : 1e18;
  }
}
