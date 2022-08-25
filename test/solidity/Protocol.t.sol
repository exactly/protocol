// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Vm } from "forge-std/Vm.sol";
import { LibString } from "solmate/src/utils/LibString.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { Test, stdError } from "forge-std/Test.sol";
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
  using FixedPointMathLib for uint128;
  using FixedPointMathLib for uint64;
  using LibString for uint256;

  uint256 internal constant N = 6;
  address internal constant BOB = address(0x420);
  address internal constant ALICE = address(0x69);
  uint256 internal constant MARKET_COUNT = 2;
  uint256 internal constant PENALTY_RATE = 0.02e18 / uint256(1 days);
  uint128 internal constant RESERVE_FACTOR = 1e17;
  uint8 internal constant MAX_FUTURE_POOLS = 3;

  address[] internal accounts;
  Auditor internal auditor;
  Market[] internal markets;
  MockERC20[] internal underlyingAssets;
  MockOracle internal oracle;

  function setUp() external {
    oracle = new MockOracle();
    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor()), "")));
    auditor.initialize(ExactlyOracle(address(oracle)), Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    InterestRateModel irm = new InterestRateModel(0.023e18, -0.0025e18, 1.02e18, 0.023e18, -0.0025e18, 1.02e18);

    accounts.push(BOB);
    accounts.push(ALICE);

    for (uint256 i = 0; i < MARKET_COUNT; ++i) {
      MockERC20 asset = new MockERC20("DAI", "DAI", 18);
      Market market = Market(address(new ERC1967Proxy(address(new Market(asset, auditor)), "")));
      market.initialize(MAX_FUTURE_POOLS, 2e18, irm, PENALTY_RATE, 1e17, RESERVE_FACTOR, 0.0046e18, 0.42e18);
      vm.label(address(market), string.concat("Market", i.toString()));
      // market.setTreasury(address(this), 0.1e18);
      auditor.enableMarket(market, 0.9e18, 18);

      asset.approve(address(market), type(uint256).max);
      for (uint256 j = 0; j < accounts.length; ++j) {
        vm.prank(accounts[j]);
        asset.approve(address(market), type(uint256).max);
      }

      asset.mint(ALICE, type(uint128).max);

      markets.push(market);
      underlyingAssets.push(asset);
    }

    vm.label(BOB, "bob");
    vm.label(ALICE, "alice");
  }

  function testFuzzSingleAccountFloatingOperations(
    uint8[N * 2 * 4] calldata timing,
    uint8[N * 2 * 4] calldata values,
    uint80[N * 2 * MARKET_COUNT] calldata prices
  ) external {
    for (uint256 i = 0; i < N * 2; i++) {
      if (timing[i * 4 + 0] > 0) vm.warp(block.timestamp + timing[i * 4 + 0]);
      if (values[i * 4 + 0] > 0) deposit(i, values[i * 4 + 0]);

      if (timing[i * 4 + 1] > 0) vm.warp(block.timestamp + timing[i * 4 + 1]);
      if (values[i * 4 + 1] > 0) borrow(i, values[i * 4 + 1]);

      if (timing[i * 4 + 2] > 0) vm.warp(block.timestamp + timing[i * 4 + 2]);
      if (values[i * 4 + 2] > 0) repay(i, values[i * 4 + 2]);

      if (timing[i * 4 + 3] > 0) vm.warp(block.timestamp + timing[i * 4 + 3]);
      if (values[i * 4 + 3] > 0) withdraw(i, values[i * 4 + 3]);

      for (uint256 j = 0; j < MARKET_COUNT; j++) {
        if (prices[i * MARKET_COUNT + j] > 0) oracle.setPrice(markets[j], prices[i * MARKET_COUNT + j]);
        liquidate(j);
      }
    }
  }

  function deposit(uint256 i, uint256 assets) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    underlyingAssets[(i / 2) % underlyingAssets.length].mint(account, assets);
    if (market.totalSupply() > 0 && market.totalAssets() == 0) {
      Market otherMarket = markets[(i / 2 + 1) % markets.length];
      MockERC20 asset = MockERC20(address(market.asset()));
      MockERC20 otherAsset = MockERC20(address(otherMarket.asset()));
      address rando = address(bytes20(blockhash(block.number - 1)));
      uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
      vm.startPrank(rando);
      asset.mint(rando, type(uint96).max);
      asset.approve(address(market), type(uint256).max);
      otherAsset.mint(rando, type(uint96).max);
      otherAsset.approve(address(otherMarket), type(uint256).max);
      otherMarket.deposit(type(uint96).max, rando);
      auditor.enterMarket(otherMarket);
      market.depositAtMaturity(maturity, 1_000_000, 0, rando);
      market.borrowAtMaturity(maturity, 1_000_000, type(uint256).max, rando, rando);
      vm.warp(block.timestamp + 1 days);
      vm.stopPrank();
    }
    uint256 expectedShares = market.convertToShares(assets);

    if (expectedShares == 0) vm.expectRevert("ZERO_SHARES");
    else {
      vm.expectEmit(true, true, true, true, address(market));
      emit Deposit(account, account, assets, expectedShares);
    }
    vm.prank(account);
    market.deposit(assets, account);
    vm.prank(account);
    auditor.enterMarket(market);
  }

  function borrow(uint256 i, uint256 assets) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    uint256 expectedShares = market.previewBorrow(assets);
    (uint256 collateral, uint256 debt) = accountLiquidity(account, market, 0, market.previewRefund(expectedShares));

    if (
      market.floatingBackupBorrowed() + market.floatingDebt() + assets >
      market.floatingAssets().mulWadDown(1e18 - RESERVE_FACTOR)
    ) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else if (debt > collateral) {
      vm.expectRevert(InsufficientAccountLiquidity.selector);
    } else {
      vm.expectEmit(true, true, true, true, address(market));
      emit Borrow(account, account, account, assets, expectedShares);
    }
    vm.prank(account);
    market.borrow(assets, account, account);
  }

  function repay(uint256 i, uint256 assets) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    uint256 borrowShares = Math.min(market.previewRepay(assets), market.floatingBorrowShares(account));
    uint256 refundAssets = market.previewRefund(borrowShares);

    if (refundAssets == 0) vm.expectRevert(ZeroRepay.selector);
    else {
      vm.expectEmit(true, true, true, true, address(market));
      emit Repay(account, account, refundAssets, borrowShares);
    }
    vm.prank(account);
    market.repay(assets, account);
  }

  function withdraw(uint256 i, uint256 assets) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    (, , uint256 index, ) = auditor.markets(market);
    uint256 expectedShares = market.totalAssets() != 0 ? market.previewWithdraw(assets) : 0;
    (uint256 collateral, uint256 debt) = accountLiquidity(account, market, assets, 0);

    if ((auditor.accountMarkets(account) & (1 << index)) != 0 && debt > collateral) {
      vm.expectRevert(InsufficientAccountLiquidity.selector);
    } else if (assets > market.floatingAssets() + previewAccumulatedEarnings(market)) {
      vm.expectRevert(stdError.arithmeticError);
    } else if (market.floatingBackupBorrowed() + market.floatingDebt() > market.floatingAssets() - assets) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else if (market.totalSupply() > 0 && market.totalAssets() == 0) {
      vm.expectRevert();
    } else if (expectedShares > market.balanceOf(account)) {
      vm.expectRevert(stdError.arithmeticError);
    } else if (assets > market.asset().balanceOf(address(market))) {
      vm.expectRevert("TRANSFER_FAILED");
    } else {
      vm.expectEmit(true, true, true, true, address(market));
      emit Withdraw(account, account, account, assets, expectedShares);
    }
    vm.prank(account);
    market.withdraw(assets, account, account);
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
    uint256 repaidAssets = market.liquidate(BOB, type(uint256).max, collateralMarket);
    if (repaidAssets > 0) {
      // if collateral is 0 then debt should be 0
      (uint256 balanceRM, uint256 debtRM) = market.accountSnapshot(BOB);
      (uint256 balanceCM, uint256 debtCM) = collateralMarket.accountSnapshot(BOB);
      if (balanceRM + balanceCM == 0) assertEq(debtRM + debtCM, 0, "should have cleared debt");
    }
  }

  function seizeAssets(
    Market market,
    Market collateralMarket,
    address account
  ) internal view returns (uint256 assets) {
    uint256 maxAssets = auditor.checkLiquidation(market, collateralMarket, BOB, type(uint256).max);
    uint256 shares = market.floatingBorrowShares(account);
    if (maxAssets > 0 && shares > 0) {
      uint256 borrowShares = market.previewRepay(maxAssets);
      if (borrowShares > 0) {
        borrowShares = Math.min(borrowShares, shares);
        (, assets) = auditor.calculateSeize(market, collateralMarket, account, market.previewRefund(borrowShares));
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

  function previewAccumulatedEarnings(Market market) internal view returns (uint256) {
    uint256 elapsed = block.timestamp - market.lastAccumulatorAccrual();
    if (elapsed == 0) return 0;
    return
      market.earningsAccumulator().mulDivDown(
        elapsed,
        elapsed + market.earningsAccumulatorSmoothFactor().mulWadDown(market.maxFuturePools() * FixedLib.INTERVAL)
      );
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
