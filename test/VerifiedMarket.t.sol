// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { VerifiedMarket } from "../contracts/verified/VerifiedMarket.sol";

contract VerifiedMarketTest is Test {
  VerifiedMarket public market;

  function setUp() public {
    // market = new VerifiedMarket();
  }

  function testLiquidateFrozenAccount() external {
    //   market.deposit(10 ether, address(this));
    //   marketWETH.deposit(10 ether, BOB);
    //   uint256 debt = 6 ether;
    //   vm.startPrank(BOB);
    //   auditor.enterMarket(marketWETH);
    //   market.borrow(debt, BOB, BOB);
    //   vm.stopPrank();
    //   auditor.setIsFrozen(BOB, true);
    //   uint256 prevBalance = weth.balanceOf(address(this));
    //   uint256 repaidAssets = market.liquidate(BOB, debt / 2, marketWETH);
    //   assertEq(repaidAssets, debt / 2);
    //   assertEq(weth.balanceOf(address(this)) - prevBalance, debt / 2);
    //   repaidAssets = market.liquidate(BOB, debt / 2, marketWETH);
    //   assertEq(repaidAssets, debt / 2);
    //   assertEq(weth.balanceOf(address(this)) - prevBalance, debt);
  }

  function testLiquidateFrozenAccountUnderwater() external {
    //   market.deposit(100_000 ether, address(this));
    //   uint256 collateral = 10 ether;
    //   marketWETH.deposit(collateral, BOB);
    //   uint256 debt = 5 ether;
    //   vm.startPrank(BOB);
    //   auditor.enterMarket(marketWETH);
    //   market.borrow(debt, BOB, BOB);
    //   vm.stopPrank();
    //   auditor.setIsFrozen(BOB, true);
    //   daiPriceFeed.setPrice(4e18); // debt * 4, now the collateral can only cover half debt
    //   uint256 prevBalance = weth.balanceOf(address(this));
    //   uint256 repaidAssets = market.liquidate(BOB, debt, marketWETH);
    //   assertEq(weth.balanceOf(address(this)) - prevBalance, collateral, "collateral obtained != full collateral");
    //   assertEq(repaidAssets, debt / 2, "repaidAssets != full debt");
  }
}
