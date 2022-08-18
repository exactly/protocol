// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Vm } from "forge-std/Vm.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Market, ZeroRepay, InsufficientProtocolLiquidity, ZeroWithdraw } from "../../contracts/Market.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";
import {
  Auditor,
  ExactlyOracle,
  AuditorMismatch,
  InsufficientAccountLiquidity,
  InsufficientShortfall,
  MarketAlreadyListed,
  RemainingDebt
} from "../../contracts/Auditor.sol";

contract ProtocolTest is Test {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint64;

  uint256 internal constant N = 6;
  address internal constant BOB = address(0x420);
  address internal constant ALICE = address(0x69);
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
      vm.prank(ALICE);
      asset.approve(address(market), type(uint256).max);
      asset.approve(address(market), type(uint256).max);

      asset.mint(ALICE, type(uint128).max);

      markets.push(market);
      underlyingAssets.push(asset);
    }

    vm.label(BOB, "bob");
    vm.label(ALICE, "alice");
  }

  function testFuzzSingleAccountFloatingOperations(
    uint8[N * 4] calldata timing,
    uint8[N * 4] calldata values,
    uint80[N * MARKET_COUNT] calldata prices
  ) external {
    for (uint256 i = 0; i < N; i++) {
      if (timing[i * 4 + 0] > 0) vm.warp(block.timestamp + timing[i * 4 + 0]);
      if (values[i * 4 + 0] > 0) deposit(i % markets.length, values[i * 4 + 0]);

      if (timing[i * 4 + 1] > 0) vm.warp(block.timestamp + timing[i * 4 + 1]);
      if (values[i * 4 + 1] > 0) borrow(i % markets.length, values[i * 4 + 1]);

      if (timing[i * 4 + 2] > 0) vm.warp(block.timestamp + timing[i * 4 + 2]);
      if (values[i * 4 + 2] > 0) repay(i % markets.length, values[i * 4 + 2]);

      if (timing[i * 4 + 3] > 0) vm.warp(block.timestamp + timing[i * 4 + 3]);
      if (values[i * 4 + 3] > 0) withdraw(i % markets.length, values[i * 4 + 3]);

      for (uint256 j = 0; j < MARKET_COUNT; j++) {
        if (prices[i * MARKET_COUNT + j] > 0) oracle.setPrice(markets[j], prices[i * MARKET_COUNT + j]);
        liquidate(j);
      }
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
    uint256 expectedShares = market.previewBorrow(assets);
    (uint256 collateral, uint256 debt) = accountLiquidity(BOB, market, 0, market.previewRefund(expectedShares));

    if (
      market.floatingBackupBorrowed() + market.floatingDebt() + assets >
      market.floatingAssets().mulWadDown(1e18 - RESERVE_FACTOR)
    ) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else if (debt > collateral) {
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
    (, , uint256 index, ) = auditor.markets(market);
    uint256 expectedShares = market.previewWithdraw(assets);
    (uint256 collateral, uint256 debt) = accountLiquidity(BOB, market, assets, 0);

    if ((auditor.accountMarkets(BOB) & (1 << index)) != 0 && debt > collateral) {
      vm.expectRevert(InsufficientAccountLiquidity.selector);
    } else if (assets > market.floatingAssets()) {
      vm.expectRevert(stdError.arithmeticError);
    } else if (market.floatingBackupBorrowed() + market.floatingDebt() > market.floatingAssets() - assets) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else {
      vm.expectEmit(true, true, true, true, address(market));
      emit Withdraw(BOB, BOB, BOB, assets, expectedShares);
    }
    vm.prank(BOB);
    market.withdraw(assets, BOB, BOB);
  }

  function liquidate(uint256 i) internal {
    Market market = markets[i];
    Market collateralMarket = markets[(i + 1) % MARKET_COUNT];
    (, , uint256 index, ) = auditor.markets(market);
    (, , uint256 collateralIndex, ) = auditor.markets(collateralMarket);
    (uint256 collateral, uint256 debt) = accountLiquidity(BOB, Market(address(0)), 0, 0);

    if (collateral >= debt) {
      vm.expectRevert(InsufficientShortfall.selector);
    } else if (notAdjustedCollateral(BOB) == 0) {
      vm.expectRevert();
    } else if (
      (auditor.accountMarkets(BOB) & (1 << collateralIndex)) == 0 || seizeAvailable(BOB, collateralMarket) == 0
    ) {
      vm.expectRevert(ZeroRepay.selector);
    } else if ((auditor.accountMarkets(BOB) & (1 << index)) == 0) {
      vm.expectRevert();
    } else if (market.previewDebt(BOB) == 0) {
      vm.expectRevert(ZeroWithdraw.selector);
    } else if (
      collateralMarket.floatingBackupBorrowed() + collateralMarket.floatingDebt() >
      collateralMarket.floatingAssets() - seizeAssets(market, collateralMarket, BOB)
    ) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else {
      vm.expectEmit(true, true, true, false, address(market));
      emit Liquidate(ALICE, BOB, 0, 0, collateralMarket, 0);
    }
    vm.prank(ALICE);
    market.liquidate(BOB, type(uint256).max, collateralMarket);
  }

  function seizeAssets(
    Market market,
    Market collateralMarket,
    address account
  ) internal view returns (uint256 seizeAssets) {
    (uint256 maxAssets, ) = auditor.checkLiquidation(market, collateralMarket, BOB, type(uint256).max);
    uint256 shares = market.floatingBorrowShares(account);
    if (maxAssets > 0 && shares > 0) {
      uint256 borrowShares = market.previewRepay(maxAssets);
      if (borrowShares > 0) {
        borrowShares = Math.min(borrowShares, shares);
        (seizeAssets, ) = auditor.calculateSeize(market, collateralMarket, account, market.previewRefund(borrowShares));
      }
    }
  }

  function notAdjustedCollateral(address account) internal view returns (uint256 sumCollateral) {
    uint256 marketMap = auditor.accountMarkets(account);
    for (uint256 i = 0; i < auditor.allMarkets().length; ++i) {
      Market market = auditor.marketList(i);
      if ((marketMap & (1 << i)) != 0) {
        (, uint8 decimals, , ) = auditor.markets(market);
        (uint256 balance, ) = market.accountSnapshot(account);
        sumCollateral += balance.mulDivDown(oracle.assetPrice(market), 10**decimals);
      }
      if ((1 << i) > marketMap) break;
    }
  }

  function seizeAvailable(address account, Market market) internal view returns (uint256) {
    uint256 collateral = market.convertToAssets(market.balanceOf(account));
    (, uint8 decimals, , ) = auditor.markets(market);
    return collateral.mulDivDown(oracle.assetPrice(market), 10**decimals);
  }

  function accountLiquidity(
    address account,
    Market marketToSimulate,
    uint256 withdrawAmount,
    uint256 borrowAmount
  ) internal view returns (uint256 sumCollateral, uint256 sumDebtPlusEffects) {
    Auditor.AccountLiquidity memory vars; // holds all our calculation results

    uint256 marketMap = auditor.accountMarkets(account);
    // if simulating a borrow, add the market to the account's map
    if (borrowAmount > 0) {
      (, , uint256 index, ) = auditor.markets(marketToSimulate);
      if ((marketMap & (1 << index)) == 0) marketMap = marketMap | (1 << index);
    }
    for (uint256 i = 0; i < auditor.allMarkets().length; ++i) {
      Market market = auditor.marketList(i);
      if ((marketMap & (1 << i)) != 0) {
        (uint128 adjustFactor, uint8 decimals, , ) = auditor.markets(market);
        (vars.balance, vars.borrowBalance) = market.accountSnapshot(account);
        vars.oraclePrice = oracle.assetPrice(market);
        sumCollateral += vars.balance.mulDivDown(vars.oraclePrice, 10**decimals).mulWadDown(adjustFactor);
        sumDebtPlusEffects += (vars.borrowBalance + (market == marketToSimulate ? borrowAmount : 0))
          .mulDivUp(vars.oraclePrice, 10**decimals)
          .divWadUp(adjustFactor);
        if (market == marketToSimulate && withdrawAmount != 0) {
          sumDebtPlusEffects += withdrawAmount.mulDivDown(vars.oraclePrice, 10**decimals).mulWadDown(adjustFactor);
        }
      }
      if ((1 << i) > marketMap) break;
    }
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
  event Liquidate(
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 lendersAssets,
    Market indexed collateralMarket,
    uint256 seizedAssets
  );
}
