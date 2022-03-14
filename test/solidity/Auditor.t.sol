// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { Vm } from "forge-std/Vm.sol";
import { DSTest } from "ds-test/test.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { Auditor, IAuditor } from "../../contracts/Auditor.sol";

contract AuditorTest is DSTest {
  using FixedPointMathLib for uint256;

  Vm internal vm = Vm(HEVM_ADDRESS);
  Auditor internal auditor;
  MockFixedLender internal fixedLender;

  event MarketListed(address fixedLender);
  event MarketEntered(address indexed fixedLender, address account);
  event MarketExited(address indexed fixedLender, address account);
  event NewBorrowCap(address indexed fixedLender, uint256 newBorrowCap);

  function setUp() external {
    auditor = new Auditor(address(new MockOracle()));
    fixedLender = new MockFixedLender(auditor);
  }

  function testEnableMarket() external {
    vm.expectEmit(false, false, false, true);
    emit MarketListed(address(fixedLender));

    auditor.enableMarket(address(fixedLender), 0.8e18, "X", "x", 18);

    (
      string memory symbol,
      string memory name,
      bool isListed,
      uint256 collateralFactor,
      uint8 decimals,
      address lender
    ) = auditor.getMarketData(address(fixedLender));
    address[] memory marketAddresses = auditor.getMarketAddresses();
    assertTrue(isListed);
    assertEq(name, "x");
    assertEq(symbol, "X");
    assertEq(decimals, 18);
    assertEq(collateralFactor, 0.8e18);
    assertEq(lender, address(fixedLender));
    assertEq(marketAddresses.length, 1);
    assertEq(marketAddresses[0], address(fixedLender));
  }

  function testEnterExitMarket() external {
    fixedLender.setBalance(1 ether);
    auditor.enableMarket(address(fixedLender), 0.8e18, "X", "x", 18);
    address[] memory markets = new address[](1);
    markets[0] = address(fixedLender);

    vm.expectEmit(true, false, false, true);
    emit MarketEntered(address(fixedLender), address(this));
    auditor.enterMarkets(markets);
    (uint256 balance, uint256 borrowed) = auditor.getAccountLiquidity(address(this));
    assertEq(balance, uint256(1 ether).fmul(0.8e18, 1e18));
    assertEq(borrowed, 0);

    vm.expectEmit(true, false, false, true);
    emit MarketExited(address(fixedLender), address(this));
    auditor.exitMarket(address(fixedLender));
    (balance, borrowed) = auditor.getAccountLiquidity(address(this));
    assertEq(balance, 0);
    assertEq(borrowed, 0);
  }

  function testEnableEnterExitMultipleMarkets() external {
    address[] memory markets = new address[](4);
    for (uint256 i = 0; i < markets.length; i++) {
      markets[i] = address(new MockFixedLender(auditor));
      auditor.enableMarket(markets[i], 0.8e18, "X", "x", 18);
    }

    auditor.enterMarkets(markets);

    for (uint256 i = 0; i < markets.length; i++) {
      vm.expectEmit(true, false, false, true);
      emit MarketExited(markets[i], address(this));
      auditor.exitMarket(markets[i]);
    }
  }

  function testFailExitMarketOwning() external {
    auditor.enableMarket(address(fixedLender), 0.8e18, "X", "x", 18);
    address[] memory markets = new address[](1);
    markets[0] = address(fixedLender);
    auditor.enterMarkets(markets);
    fixedLender.setBorrowed(1);
    auditor.exitMarket(address(fixedLender));
  }

  function testFailEnableMarketAlreadyListed() external {
    auditor.enableMarket(address(fixedLender), 0.8e18, "X", "x", 18);
    auditor.enableMarket(address(fixedLender), 0.8e18, "X", "x", 18);
  }

  function testFailEnableMarketAuditorMismatch() external {
    fixedLender.setAuditor(address(0));
    auditor.enableMarket(address(fixedLender), 0.8e18, "X", "x", 18);
  }

  function testSetMarketBorrowCaps() external {
    auditor.enableMarket(address(fixedLender), 0.8e18, "X", "x", 18);
    address[] memory markets = new address[](1);
    markets[0] = address(fixedLender);
    uint256[] memory caps = new uint256[](1);
    caps[0] = 1;

    vm.expectEmit(true, false, false, true);
    emit NewBorrowCap(address(fixedLender), 1);
    auditor.setMarketBorrowCaps(markets, caps);
  }

  function testFailSetInvalidMarketBorrowCaps() external {
    auditor.enableMarket(address(fixedLender), 0.8e18, "X", "x", 18);
    address[] memory markets = new address[](1);
    uint256[] memory caps = new uint256[](2);
    auditor.setMarketBorrowCaps(markets, caps);
  }

  function testBorrowMPValidation() external {
    auditor.enableMarket(address(fixedLender), 0.8e18, "X", "x", 18);
    address[] memory markets = new address[](1);
    markets[0] = address(fixedLender);
    auditor.enterMarkets(markets);
    auditor.validateBorrowMP(address(fixedLender), address(this));
  }

  function testFailBorrowMPValidation() external {
    auditor.enableMarket(address(fixedLender), 0.8e18, "X", "x", 18);
    address[] memory markets = new address[](1);
    markets[0] = address(fixedLender);
    auditor.enterMarkets(markets);
    fixedLender.setBorrowed(1);
    auditor.validateBorrowMP(address(fixedLender), address(this));
  }

  function testAccountShortfall() external {
    auditor.enableMarket(address(fixedLender), 0.8e18, "X", "x", 18);
    address[] memory markets = new address[](1);
    markets[0] = address(fixedLender);
    auditor.enterMarkets(markets);
    auditor.validateAccountShortfall(address(fixedLender), address(this), 1);
  }

  function testFailAccountShortfall() external {
    auditor.enableMarket(address(fixedLender), 0.8e18, "X", "x", 18);
    address[] memory markets = new address[](1);
    markets[0] = address(fixedLender);
    auditor.enterMarkets(markets);
    fixedLender.setBorrowed(1);
    auditor.validateAccountShortfall(address(fixedLender), address(this), 1);
  }
}

contract MockFixedLender {
  string public underlyingTokenSymbol = "X";
  uint256 internal balance;
  uint256 internal borrowed;
  IAuditor internal auditor;

  constructor(IAuditor auditor_) {
    auditor = auditor_;
  }

  function setAuditor(address auditor_) external {
    auditor = IAuditor(auditor_);
  }

  function setBalance(uint256 balance_) external {
    balance = balance_;
  }

  function setBorrowed(uint256 borrowed_) external {
    borrowed = borrowed_;
  }

  function getAuditor() external view returns (IAuditor) {
    return auditor;
  }

  function getAccountSnapshot(address, uint256) external view returns (uint256, uint256) {
    return (balance, borrowed);
  }
}

contract MockOracle {
  function getAssetPrice(string memory) external pure returns (uint256) {
    return 1e18;
  }
}
