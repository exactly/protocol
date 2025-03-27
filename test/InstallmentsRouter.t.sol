// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17; // solhint-disable-line one-contract-per-file

import { Test, stdError } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { WETH } from "solmate/src/tokens/WETH.sol";
import { InterestRateModel } from "../contracts/InterestRateModel.sol";
import { MockInterestRateModel } from "../contracts/mocks/MockInterestRateModel.sol";
import {
  ERC20,
  Permit,
  Market,
  Auditor,
  Disagreement,
  MarketNotListed,
  InstallmentsRouter
} from "../contracts/periphery/InstallmentsRouter.sol";

import { FixedLib, UnmatchedPoolState } from "../contracts/utils/FixedLib.sol";

contract InstallmentsRouterTest is Test {
  Auditor internal auditor;
  Market internal market;
  Market internal marketWETH;
  ERC20 internal usdc;
  WETH internal weth;
  InstallmentsRouter internal router;
  uint256 internal constant BOB_KEY = 0x420;
  address internal bob;

  function setUp() external {
    usdc = new MockERC20("USD Coin", "USDC", 6);
    weth = new WETH();

    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    vm.label(address(auditor), "Auditor");

    market = Market(address(new ERC1967Proxy(address(new Market(usdc, auditor)), "")));
    market.initialize(
      "USDC.e",
      3,
      type(uint256).max,
      1e18,
      InterestRateModel(address(new MockInterestRateModel(0.1e18))),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    market.setDampSpeed(market.floatingAssetsDampSpeedUp(), market.floatingAssetsDampSpeedDown(), 0.23e18, 0.000053e18);
    market.setFixedBorrowThreshold(1e18, 0.1e18, 1e18);
    vm.label(address(market), "market");

    marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "WETH",
      3,
      type(uint256).max,
      1e18,
      InterestRateModel(address(new MockInterestRateModel(0.1e18))),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    marketWETH.setDampSpeed(
      marketWETH.floatingAssetsDampSpeedUp(),
      marketWETH.floatingAssetsDampSpeedDown(),
      0.23e18,
      0.000053e18
    );
    marketWETH.setFixedBorrowThreshold(1e18, 0.1e18, 1e18);
    vm.label(address(marketWETH), "marketWETH");

    auditor.enableMarket(market, new MockPriceFeed(18, 1e18), 0.8e18);
    auditor.enableMarket(marketWETH, new MockPriceFeed(18, 1e18), 0.8e18);

    router = new InstallmentsRouter(auditor, marketWETH);

    deal(address(usdc), address(this), 1_000_000e6);
    market.approve(address(router), type(uint256).max);
    usdc.approve(address(market), type(uint256).max);
    market.deposit(100_000e6, address(this));
    usdc.approve(address(market), 0);
    auditor.enterMarket(market);

    bob = vm.addr(BOB_KEY);
    vm.label(bob, "bob");

    deal(address(weth), 1_000_000e18);
    deal(address(weth), address(this), 1_000_000e18);
    weth.deposit{ value: 100_000e18 }();
    weth.approve(address(marketWETH), type(uint256).max);
    marketWETH.deposit(100_000e18, address(this));
    weth.approve(address(marketWETH), 0);
    marketWETH.approve(address(router), type(uint256).max);
  }

  function testBorrowRouter() external {
    uint256 initialBalance = usdc.balanceOf(address(this));
    uint256 maturity = FixedLib.INTERVAL;
    uint256[] memory amounts = new uint256[](3);
    amounts[0] = 10_000e6;
    amounts[1] = 10_000e6;
    amounts[2] = 10_000e6;
    router.borrow(market, maturity, amounts, type(uint256).max, address(this));
    uint256 finalBalance = usdc.balanceOf(address(this));
    assertEq(initialBalance + 30_000e6, finalBalance, "borrowed amounts are not correct");
  }

  function testMaxRepay() external {
    uint256 maturity = FixedLib.INTERVAL;
    uint256[] memory amounts = new uint256[](3);
    amounts[0] = 10_000e6;
    amounts[1] = 10_000e6;
    amounts[2] = 10_000e6;
    uint256 maxRepay = 31_000e6;
    uint256[] memory assetsOwed = router.borrow(market, maturity, amounts, maxRepay, address(this));

    uint256 totalOwed;
    for (uint256 i = 0; i < assetsOwed.length; i++) {
      totalOwed += assetsOwed[i];
    }
    assertLe(totalOwed, maxRepay, "maxRepay > totalOwed");
  }

  function testFakeMarket() external {
    uint256 maturity = FixedLib.INTERVAL;
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = 10_000e6;
    amounts[1] = 10_000e6;
    Market fake = Market(address(0));
    vm.expectRevert(abi.encodeWithSelector(MarketNotListed.selector));
    router.borrow(fake, maturity, amounts, type(uint256).max, address(this));
  }

  function testInsufficientMaxRepay() external {
    uint256 maturity = FixedLib.INTERVAL;
    uint256[] memory amounts = new uint256[](3);
    amounts[0] = 10_000e6;
    amounts[1] = 10_000e6;
    amounts[2] = 10_000e6;
    uint256 maxRepay = 29_000e6;

    vm.expectRevert(Disagreement.selector);
    router.borrow(market, maturity, amounts, maxRepay, address(this));
  }

  function testMoreBorrowsThanMaxPools() external {
    uint256 maturity = FixedLib.INTERVAL;
    uint256[] memory amounts = new uint256[](4);
    amounts[0] = 10_000e6;
    amounts[1] = 10_000e6;
    amounts[2] = 10_000e6;
    amounts[3] = 10_000e6;

    vm.expectRevert(
      abi.encodeWithSelector(UnmatchedPoolState.selector, FixedLib.State.NOT_READY, FixedLib.State.VALID)
    );
    router.borrow(market, maturity, amounts, type(uint256).max, address(this));
  }

  function testBorrowUnwrappedETH() external {
    uint256 maturity = FixedLib.INTERVAL;
    uint256[] memory amounts = new uint256[](3);
    amounts[0] = 10_000e18;
    amounts[1] = 10_000e18;
    amounts[2] = 10_000e18;
    uint256 maxRepay = 32_000e18;
    uint256 balanceBefore = address(this).balance;
    router.borrowETH(maturity, amounts, maxRepay, address(this));
    uint256 balanceAfter = address(this).balance;
    assertEq(balanceAfter, balanceBefore + 30_000e18, "borrow != expected");
  }

  function testBorrowWithPermit() external {
    deal(address(weth), bob, 100_000e18);

    vm.startPrank(bob);
    weth.approve(address(marketWETH), type(uint256).max);
    marketWETH.deposit(100_000e18, bob);
    auditor.enterMarket(marketWETH);
    vm.stopPrank();

    uint256 maxRepay = 35_000e6;
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          market.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              address(router),
              maxRepay,
              market.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
    uint256[] memory amounts = new uint256[](3);
    amounts[0] = 10_000e6;
    amounts[1] = 10_000e6;
    amounts[2] = 10_000e6;

    uint256 usdcBefore = usdc.balanceOf(bob);
    vm.prank(bob);
    router.borrow(market, FixedLib.INTERVAL, amounts, maxRepay, Permit(maxRepay, block.timestamp, v, r, s));

    uint256 usdcAfter = usdc.balanceOf(bob);
    uint256 totalBorrowed;
    for (uint256 i = 0; i < amounts.length; i++) {
      totalBorrowed += amounts[i];
    }
    assertEq(usdcAfter, usdcBefore + totalBorrowed, "borrow != expected");
  }

  function testBorrowETHWithPermit() external {
    deal(address(weth), bob, 100_000e18);

    vm.startPrank(bob);
    weth.approve(address(marketWETH), type(uint256).max);
    marketWETH.deposit(100_000e18, bob);
    auditor.enterMarket(marketWETH);
    vm.stopPrank();

    uint256 maxRepay = 35_000e18;
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          marketWETH.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              address(router),
              maxRepay,
              marketWETH.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
    uint256[] memory amounts = new uint256[](3);
    amounts[0] = 10_000e18;
    amounts[1] = 10_000e18;
    amounts[2] = 10_000e18;

    uint256 balanceBefore = bob.balance;
    vm.prank(bob);
    router.borrowETH(FixedLib.INTERVAL, amounts, maxRepay, Permit(maxRepay, block.timestamp, v, r, s), bob);
    assertEq(bob.balance, balanceBefore + 30_000e18, "borrow != expected");
  }

  function testAmountsLength() external {
    uint256 maturity = FixedLib.INTERVAL;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 10_000e6;

    vm.expectRevert(stdError.assertionError);
    router.borrow(market, maturity, amounts, type(uint256).max, address(this));
  }

  function testMissingMarketWETH() external {
    router = new InstallmentsRouter(auditor, Market(address(0)));
    vm.expectRevert(abi.encodeWithSelector(MarketNotListed.selector));
    router.borrowETH(FixedLib.INTERVAL, new uint256[](3), type(uint256).max, address(this));
  }

  function testBorrowToAnotherReceiver() external {
    uint256 maturity = FixedLib.INTERVAL;
    uint256[] memory amounts = new uint256[](3);
    amounts[0] = 10_000e6;
    amounts[1] = 10_000e6;
    amounts[2] = 10_000e6;
    uint256 maxRepay = 32_000e6;
    assertEq(usdc.balanceOf(bob), 0);
    router.borrow(market, maturity, amounts, maxRepay, bob);
    assertEq(usdc.balanceOf(bob), 30_000e6, "borrow != expected");
  }

  function testBorrowETHToAnotherReceiver() external {
    uint256 maturity = FixedLib.INTERVAL;
    uint256[] memory amounts = new uint256[](3);
    amounts[0] = 10_000e18;
    amounts[1] = 10_000e18;
    amounts[2] = 10_000e18;
    uint256 maxRepay = 32_000e18;
    assertEq(bob.balance, 0);
    router.borrowETH(maturity, amounts, maxRepay, bob);
    assertEq(bob.balance, 30_000e18, "borrow != expected");
  }

  receive() external payable {}
}
