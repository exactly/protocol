// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Vm } from "forge-std/Vm.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Market, ZeroRepay, InsufficientProtocolLiquidity } from "../../contracts/Market.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";
import {
  Auditor,
  ExactlyOracle,
  AuditorMismatch,
  InsufficientAccountLiquidity,
  MarketAlreadyListed,
  RemainingDebt
} from "../../contracts/Auditor.sol";

contract ProtocolTest is Test {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint64;

  uint256 internal constant N = 6;
  address internal constant BOB = address(0x420);
  uint256 internal constant MARKET_COUNT = 2;
  uint256 internal constant PENALTY_RATE = 0.02e18 / uint256(1 days);
  uint128 internal constant RESERVE_FACTOR = 1e17;
  uint8 internal constant MAX_FUTURE_POOLS = 3;

  Auditor internal auditor;
  Market[] internal markets;
  MockERC20[] internal underlyingAssets;
  MockOracle internal oracle;

  function setUp() external {
    oracle = new MockOracle();
    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor()), "")));
    auditor.initialize(ExactlyOracle(address(oracle)), Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    InterestRateModel irm = new InterestRateModel(0.023e18, -0.0025e18, 1.02e18, 0.023e18, -0.0025e18, 1.02e18);

    for (uint256 i = 0; i < MARKET_COUNT; ++i) {
      MockERC20 asset = new MockERC20("DAI", "DAI", 18);
      Market market = Market(address(new ERC1967Proxy(address(new Market(asset, auditor)), "")));
      market.initialize(MAX_FUTURE_POOLS, 2e18, irm, PENALTY_RATE, 1e17, RESERVE_FACTOR, 0.0046e18, 0.42e18);
      auditor.enableMarket(market, 0.9e18, 18);

      vm.prank(BOB);
      asset.approve(address(market), type(uint256).max);
      asset.approve(address(market), type(uint256).max);

      markets.push(market);
      underlyingAssets.push(asset);
    }

    vm.label(BOB, "bob");
  }

  function testFuzzSingleAccountFloatingOperations(uint8[N * 4] calldata timing, uint8[N * 4] calldata values)
    external
  {
    for (uint256 i = 0; i < N; i++) {
      if (timing[i * 4 + 0] > 0) vm.warp(block.timestamp + timing[i * 4 + 0]);
      if (values[i * 4 + 0] > 0) deposit(0, values[i * 4 + 0]);

      if (timing[i * 4 + 1] > 0) vm.warp(block.timestamp + timing[i * 4 + 1]);
      if (values[i * 4 + 1] > 0) borrow(0, values[i * 4 + 1]);

      if (timing[i * 4 + 2] > 0) vm.warp(block.timestamp + timing[i * 4 + 2]);
      if (values[i * 4 + 2] > 0) repay(0, values[i * 4 + 2]);

      if (timing[i * 4 + 3] > 0) vm.warp(block.timestamp + timing[i * 4 + 3]);
      if (values[i * 4 + 3] > 0) withdraw(0, values[i * 4 + 3]);
    }
  }

  function deposit(uint256 i, uint256 assets) internal {
    Market market = markets[i];
    underlyingAssets[i].mint(BOB, assets);
    uint256 expectedShares = market.convertToShares(assets);
    if (expectedShares == 0) vm.expectRevert("ZERO_SHARES");
    else {
      vm.expectEmit(true, true, true, true, address(market));
      emit Deposit(BOB, BOB, assets, expectedShares);
    }
    vm.prank(BOB);
    market.deposit(assets, BOB);
  }

  function borrow(uint256 i, uint256 assets) internal {
    Market market = markets[i];
    (uint128 adjustFactor, , , ) = auditor.markets(market);
    uint256 expectedShares = market.previewBorrow(assets);
    if (
      market.floatingBackupBorrowed() + market.floatingDebt() + assets >
      market.floatingAssets().mulWadDown(1e18 - RESERVE_FACTOR)
    ) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else if (
      (market.previewDebt(BOB) + assets).divWadUp(adjustFactor) > market.maxWithdraw(BOB).mulWadDown(adjustFactor)
    ) {
      vm.expectRevert(InsufficientAccountLiquidity.selector);
    } else {
      vm.expectEmit(true, true, true, true, address(market));
      emit Borrow(BOB, BOB, BOB, assets, expectedShares);
    }
    vm.prank(BOB);
    market.borrow(assets, BOB, BOB);
  }

  function repay(uint256 i, uint256 assets) internal {
    Market market = markets[i];
    uint256 borrowShares = Math.min(market.previewRepay(assets), market.floatingBorrowShares(BOB));
    uint256 refundAssets = market.previewRefund(borrowShares);
    if (refundAssets == 0) vm.expectRevert(ZeroRepay.selector);
    else {
      vm.expectEmit(true, true, true, true, address(market));
      emit Repay(BOB, BOB, refundAssets, borrowShares);
    }
    vm.prank(BOB);
    market.repay(assets, BOB);
  }

  function withdraw(uint256 i, uint256 assets) internal {
    Market market = markets[i];
    (uint128 adjustFactor, , uint256 index, ) = auditor.markets(market);
    uint256 expectedShares = market.previewWithdraw(assets);
    if (
      (auditor.accountMarkets(BOB) & (1 << index)) == 1 &&
      (market.previewDebt(BOB)).divWadUp(adjustFactor) + assets.mulWadDown(adjustFactor) >
      market.convertToAssets(market.balanceOf(BOB)).mulWadDown(adjustFactor)
    ) {
      vm.expectRevert(InsufficientAccountLiquidity.selector);
    } else if (assets > market.floatingAssets()) {
      vm.expectRevert(stdError.arithmeticError);
    } else {
      vm.expectEmit(true, true, true, true, address(market));
      emit Withdraw(BOB, BOB, BOB, assets, expectedShares);
    }
    vm.prank(BOB);
    market.withdraw(assets, BOB, BOB);
  }

  event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
  event Borrow(
    address indexed caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 shares
  );
  event Repay(address indexed caller, address indexed borrower, uint256 assets, uint256 shares);
  event Withdraw(
    address indexed caller,
    address indexed receiver,
    address indexed owner,
    uint256 assets,
    uint256 shares
  );
}
