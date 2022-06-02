// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { Auditor, FixedLender, ExactlyOracle } from "../../contracts/Auditor.sol";

contract AuditorTest is Test {
  using FixedPointMathLib for uint256;

  Auditor internal auditor;
  MockFixedLender internal fixedLender;

  event MarketListed(FixedLender fixedLender);
  event MarketEntered(FixedLender indexed fixedLender, address account);
  event MarketExited(FixedLender indexed fixedLender, address account);

  function setUp() external {
    auditor = new Auditor(ExactlyOracle(address(new MockOracle())), 1.1e18);
    fixedLender = new MockFixedLender(auditor);
  }

  function testEnableMarket() external {
    vm.expectEmit(false, false, false, true);
    emit MarketListed(FixedLender(address(fixedLender)));

    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, "X", "x", 18);

    (
      string memory symbol,
      string memory name,
      bool isListed,
      uint256 collateralFactor,
      uint8 decimals,
      FixedLender lender
    ) = auditor.getMarketData(FixedLender(address(fixedLender)));
    FixedLender[] memory markets = auditor.getAllMarkets();
    assertTrue(isListed);
    assertEq(name, "x");
    assertEq(symbol, "X");
    assertEq(decimals, 18);
    assertEq(collateralFactor, 0.8e18);
    assertEq(markets.length, 1);
    assertEq(address(lender), address(fixedLender));
    assertEq(address(markets[0]), address(fixedLender));
  }

  function testEnterExitMarket() external {
    fixedLender.setBalance(1 ether);
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, "X", "x", 18);

    vm.expectEmit(true, false, false, true);
    emit MarketEntered(FixedLender(address(fixedLender)), address(this));
    auditor.enterMarket(FixedLender(address(fixedLender)));
    (uint256 collateral, uint256 debt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    assertEq(collateral, uint256(1 ether).mulWadDown(0.8e18));
    assertEq(debt, 0);

    vm.expectEmit(true, false, false, true);
    emit MarketExited(FixedLender(address(fixedLender)), address(this));
    auditor.exitMarket(FixedLender(address(fixedLender)));
    (collateral, debt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    assertEq(collateral, 0);
    assertEq(debt, 0);
  }

  function testEnableEnterExitMultipleMarkets() external {
    FixedLender[] memory markets = new FixedLender[](4);
    for (uint256 i = 0; i < markets.length; i++) {
      markets[i] = FixedLender(address(new MockFixedLender(auditor)));
      auditor.enableMarket(markets[i], 0.8e18, "X", "x", 18);
      auditor.enterMarket(markets[i]);
      vm.expectEmit(true, false, false, true);
      emit MarketExited(markets[i], address(this));
      auditor.exitMarket(markets[i]);
    }
  }

  function testFailExitMarketOwning() external {
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, "X", "x", 18);
    auditor.enterMarket(FixedLender(address(fixedLender)));
    fixedLender.setBorrowed(1);
    auditor.exitMarket(FixedLender(address(fixedLender)));
  }

  function testFailEnableMarketAlreadyListed() external {
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, "X", "x", 18);
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, "X", "x", 18);
  }

  function testFailEnableMarketAuditorMismatch() external {
    fixedLender.setAuditor(address(0));
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, "X", "x", 18);
  }

  function testBorrowMPValidation() external {
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, "X", "x", 18);
    auditor.enterMarket(FixedLender(address(fixedLender)));
    auditor.validateBorrowMP(FixedLender(address(fixedLender)), address(this));
  }

  function testFailBorrowMPValidation() external {
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, "X", "x", 18);
    auditor.enterMarket(FixedLender(address(fixedLender)));
    fixedLender.setBorrowed(1);
    auditor.validateBorrowMP(FixedLender(address(fixedLender)), address(this));
  }

  function testAccountShortfall() external {
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, "X", "x", 18);
    auditor.enterMarket(FixedLender(address(fixedLender)));
    auditor.validateAccountShortfall(FixedLender(address(fixedLender)), address(this), 1);
  }

  function testFailAccountShortfall() external {
    auditor.enableMarket(FixedLender(address(fixedLender)), 0.8e18, "X", "x", 18);
    auditor.enterMarket(FixedLender(address(fixedLender)));
    fixedLender.setBorrowed(1);
    auditor.validateAccountShortfall(FixedLender(address(fixedLender)), address(this), 1);
  }
}

contract MockFixedLender {
  Auditor public auditor;
  uint256 internal balance;
  uint256 internal borrowed;

  constructor(Auditor auditor_) {
    auditor = auditor_;
  }

  function setAuditor(address auditor_) external {
    auditor = Auditor(auditor_);
  }

  function setBalance(uint256 balance_) external {
    balance = balance_;
  }

  function setBorrowed(uint256 borrowed_) external {
    borrowed = borrowed_;
  }

  function getAccountSnapshot(address, uint256) external view returns (uint256, uint256) {
    return (balance, borrowed);
  }
}

contract MockOracle {
  function getAssetPrice(FixedLender) external pure returns (uint256) {
    return 1e18;
  }
}
