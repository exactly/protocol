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
import { InterestRateModel, UtilizationExceeded } from "../../contracts/InterestRateModel.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";
import {
  Auditor,
  RemainingDebt,
  ExactlyOracle,
  AuditorMismatch,
  InsufficientAccountLiquidity,
  InsufficientShortfall,
  MarketAlreadyListed,
  RemainingDebt
} from "../../contracts/Auditor.sol";

contract ProtocolTest is Test {
  using FixedPointMathLib for int256;
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;
  using FixedPointMathLib for uint64;
  using LibString for uint256;
  using FixedLib for FixedLib.Position;

  uint256 internal constant N = 6;
  address internal constant BOB = address(0x420);
  address internal constant ALICE = address(0x69);
  address internal constant MARIA = address(0x42069);
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
    uint16[N * 2 * 9] calldata timing,
    uint16[N * 2 * 9] calldata values,
    uint80[N * 2 * MARKET_COUNT] calldata prices
  ) external {
    for (uint256 i = 0; i < N * 2; ++i) {
      if (values[i * 4 + 0] % 2 == 0) enterMarket(i);
      if (values[i * 4 + 0] % 2 == 1) exitMarket(i);

      if (timing[i * 4 + 0] > 0) vm.warp(block.timestamp + timing[i * 4 + 0]);
      if (values[i * 4 + 0] > 0) deposit(i, values[i * 4 + 0]);

      if (timing[i * 4 + 1] > 0) vm.warp(block.timestamp + timing[i * 4 + 1]);
      if (values[i * 4 + 1] > 0) borrow(i, values[i * 4 + 1]);

      if (timing[i * 4 + 2] > 0) vm.warp(block.timestamp + timing[i * 4 + 2]);
      if (values[i * 4 + 2] > 0) repay(i, values[i * 4 + 2]);

      if (timing[i * 4 + 3] > 0) vm.warp(block.timestamp + timing[i * 4 + 3]);
      if (values[i * 4 + 3] > 0) withdraw(i, values[i * 4 + 3]);

      if (timing[i * 4 + 4] > 0) vm.warp(block.timestamp + timing[i * 4 + 4]);
      if (values[i * 4 + 4] > 0) transfer(i, values[i * 4 + 4]);

      if (timing[i * 4 + 5] > 0) vm.warp(block.timestamp + timing[i * 4 + 5]);
      if (values[i * 4 + 5] > 0) depositAtMaturity(i, values[i * 4 + 5]);

      if (timing[i * 4 + 6] > 0) vm.warp(block.timestamp + timing[i * 4 + 6]);
      if (values[i * 4 + 6] > 0) withdrawAtMaturity(i, values[i * 4 + 6]);

      if (timing[i * 4 + 7] > 0) vm.warp(block.timestamp + timing[i * 4 + 7]);
      if (values[i * 4 + 7] > 0) borrowAtMaturity(i, values[i * 4 + 7]);

      if (timing[i * 4 + 8] > 0) vm.warp(block.timestamp + timing[i * 4 + 8]);
      if (values[i * 4 + 8] > 0) repayAtMaturity(i, values[i * 4 + 8]);

      for (uint256 j = 0; j < MARKET_COUNT; j++) {
        if (prices[i * MARKET_COUNT + j] > 0) oracle.setPrice(markets[j], prices[i * MARKET_COUNT + j]);
        // liquidate(j);
      }
      checkInvariants();
    }
  }

  function depositAtMaturity(uint256 i, uint256 assets) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    underlyingAssets[(i / 2) % underlyingAssets.length].mint(account, assets);
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;

    vm.expectEmit(true, true, true, false, address(market));
    emit DepositAtMaturity(maturity, account, account, assets, 0);
    vm.prank(account);
    market.depositAtMaturity(maturity, assets, 0, account);
  }

  function withdrawAtMaturity(uint256 i, uint256 assets) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    (uint256 borrowed, uint256 supplied, , ) = market.fixedPools(maturity);
    (uint256 principal, uint256 fee) = market.fixedDepositPositions(maturity, account);
    uint256 positionAssets = assets > principal + fee ? principal + fee : assets;
    uint256 backupAssets = previewFloatingAssetsAverage(market);

    if (block.timestamp < maturity && supplied + backupAssets == 0) {
      vm.expectRevert();
    } else if (
      (block.timestamp < maturity && positionAssets > backupAssets + supplied) ||
      (borrowed + positionAssets).divWadUp(backupAssets + supplied) > 1e18
    ) {
      vm.expectRevert(UtilizationExceeded.selector);
    } else if (
      block.timestamp < maturity && ((supplied + previewFloatingAssetsAverage(market) == 0) || principal + fee == 0)
    ) {
      vm.expectRevert();
    } else if (
      market.floatingBackupBorrowed() +
        Math.min(supplied, borrowed) -
        Math.min(supplied - FixedLib.Position(principal, fee).scaleProportionally(positionAssets).principal, borrowed) +
        market.totalFloatingBorrowAssets() >
      market.floatingAssets() + previewNewFloatingDebt(market)
    ) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else if (
      (
        block.timestamp < maturity
          ? positionAssets.divWadDown(
            1e18 +
              market.interestRateModel().fixedBorrowRate(maturity, positionAssets, borrowed, supplied, backupAssets)
          )
          : positionAssets
      ) > market.asset().balanceOf(address(market))
    ) {
      vm.expectRevert("TRANSFER_FAILED");
    } else {
      vm.expectEmit(true, true, true, false, address(market));
      emit WithdrawAtMaturity(maturity, account, account, account, assets, 0);
    }
    vm.prank(account);
    market.withdrawAtMaturity(maturity, assets, 0, account, account);
  }

  function repayAtMaturity(uint256 i, uint256 assets) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    (uint256 principal, uint256 fee) = market.fixedBorrowPositions(maturity, account);
    underlyingAssets[(i / 2) % underlyingAssets.length].mint(account, fee);
    uint256 positionAssets = assets > principal + fee ? principal + fee : assets;

    if (positionAssets == 0) {
      vm.expectRevert(ZeroRepay.selector);
    } else if (
      positionAssets <
      previewDepositYield(
        market,
        maturity,
        FixedLib.Position(principal, fee).scaleProportionally(positionAssets).principal
      )
    ) {
      vm.expectRevert(stdError.arithmeticError);
    } else {
      vm.expectEmit(true, true, true, false, address(market));
      emit RepayAtMaturity(maturity, account, account, 0, 0);
    }
    vm.prank(account);
    market.repayAtMaturity(maturity, positionAssets, type(uint256).max, account);
  }

  function borrowAtMaturity(uint256 i, uint256 assets) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    (uint256 borrowed, uint256 supplied, , ) = market.fixedPools(maturity);
    uint256 backupAssets = previewFloatingAssetsAverage(market);
    uint256 backupDebtAddition;
    {
      uint256 newBorrowed = borrowed + assets;
      backupDebtAddition = newBorrowed - Math.min(Math.max(borrowed, supplied), newBorrowed);
    }

    if (supplied + backupAssets == 0) {
      vm.expectRevert();
    } else if (assets > backupAssets + supplied || (borrowed + assets).divWadUp(backupAssets + supplied) > 1e18) {
      vm.expectRevert(UtilizationExceeded.selector);
    } else if (
      backupDebtAddition > 0 &&
      market.floatingBackupBorrowed() + backupDebtAddition + market.totalFloatingBorrowAssets() >
      (market.floatingAssets() + previewNewFloatingDebt(market)).mulWadDown(1e18 - RESERVE_FACTOR)
    ) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else {
      uint256 fees = assets.mulWadDown(
        market.interestRateModel().fixedBorrowRate(maturity, assets, borrowed, supplied, backupAssets)
      );
      (uint256 collateral, uint256 debt) = accountLiquidity(account, market, assets + fees, 0);
      if (collateral < debt) {
        vm.expectRevert(InsufficientAccountLiquidity.selector);
      } else if (assets > market.asset().balanceOf(address(market))) {
        vm.expectRevert("TRANSFER_FAILED");
      } else {
        vm.expectEmit(true, true, true, true, address(market));
        emit BorrowAtMaturity(maturity, account, account, account, assets, fees);
      }
    }
    vm.prank(account);
    market.borrowAtMaturity(maturity, assets, type(uint256).max, account, account);
  }

  function deposit(uint256 i, uint256 assets) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    underlyingAssets[(i / 2) % underlyingAssets.length].mint(account, assets);
    if (market.totalSupply() > 0 && market.totalAssets() == 0) {
      Market otherMarket = markets[(i / 2 + 1) % markets.length];
      MockERC20 asset = MockERC20(address(market.asset()));
      MockERC20 otherAsset = MockERC20(address(otherMarket.asset()));
      uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
      vm.startPrank(MARIA);
      asset.mint(MARIA, type(uint96).max);
      asset.approve(address(market), type(uint256).max);
      otherAsset.mint(MARIA, type(uint96).max);
      otherAsset.approve(address(otherMarket), type(uint256).max);
      otherMarket.deposit(type(uint96).max, MARIA);
      auditor.enterMarket(otherMarket);
      FixedLib.Pool memory pool;
      (pool.borrowed, pool.supplied, , ) = market.fixedPools(maturity);
      market.depositAtMaturity(maturity, pool.borrowed - Math.min(pool.borrowed, pool.supplied) + 1_000_000, 0, MARIA);
      market.borrowAtMaturity(maturity, 1_000_000, type(uint256).max, MARIA, MARIA);
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
  }

  function enterMarket(uint256 i) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    (, , uint256 index, ) = auditor.markets(market);

    if ((auditor.accountMarkets(account) & (1 << index)) == 0) {
      vm.expectEmit(true, true, true, true, address(auditor));
      emit MarketEntered(market, account);
    }
    vm.prank(account);
    auditor.enterMarket(market);
  }

  function exitMarket(uint256 i) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    (, , uint256 index, ) = auditor.markets(market);
    (uint256 balance, uint256 debt) = market.accountSnapshot(account);
    (uint256 adjustedCollateral, uint256 adjustedDebt) = accountLiquidity(account, market, 0, balance);
    uint256 marketMap = auditor.accountMarkets(account);

    if ((marketMap & (1 << index)) != 0) {
      if (debt > 0) {
        vm.expectRevert(RemainingDebt.selector);
      } else if (adjustedCollateral < adjustedDebt) {
        vm.expectRevert(InsufficientAccountLiquidity.selector);
      } else {
        vm.expectEmit(true, true, true, true, address(auditor));
        emit MarketExited(market, account);
      }
    }
    vm.prank(account);
    auditor.exitMarket(market);
    if ((marketMap & (1 << index)) == 0) assertEq(marketMap, auditor.accountMarkets(account));
  }

  function borrow(uint256 i, uint256 assets) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    uint256 expectedShares = market.previewBorrow(assets);
    (uint256 collateral, uint256 debt) = previewAccountLiquidity(account, market, assets, expectedShares);

    if (
      market.floatingBackupBorrowed() + market.totalFloatingBorrowAssets() + assets >
      (market.floatingAssets() + previewNewFloatingDebt(market)).mulWadDown(1e18 - RESERVE_FACTOR)
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
    underlyingAssets[(i / 2) % underlyingAssets.length].mint(account, assets);
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
    (uint256 collateral, uint256 debt) = accountLiquidity(account, market, 0, assets);
    uint256 earnings = previewAccumulatedEarnings(market);

    if ((auditor.accountMarkets(account) & (1 << index)) != 0 && debt > collateral) {
      vm.expectRevert(InsufficientAccountLiquidity.selector);
    } else if (market.totalSupply() > 0 && market.totalAssets() == 0) {
      vm.expectRevert();
    } else if (assets > market.floatingAssets() + previewNewFloatingDebt(market) + earnings) {
      vm.expectRevert(stdError.arithmeticError);
    } else if (
      market.floatingBackupBorrowed() + market.totalFloatingBorrowAssets() >
      market.floatingAssets() + previewNewFloatingDebt(market) + earnings - assets
    ) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
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

  function transfer(uint256 i, uint256 shares) internal {
    Market market = markets[(i / 2) % markets.length];
    address account = accounts[i % accounts.length];
    address otherAccount = accounts[(i + 1) % accounts.length];
    (, , uint256 index, ) = auditor.markets(market);
    uint256 withdrawAssets = market.previewMint(shares);
    (uint256 collateral, uint256 debt) = accountLiquidity(account, market, 0, withdrawAssets);

    if ((auditor.accountMarkets(account) & (1 << index)) != 0 && debt > collateral) {
      vm.expectRevert(InsufficientAccountLiquidity.selector);
    } else if (shares > market.balanceOf(account)) {
      vm.expectRevert(stdError.arithmeticError);
    } else {
      vm.expectEmit(true, true, true, true, address(market));
      emit Transfer(account, otherAccount, shares);
    }
    vm.prank(account);
    market.transfer(otherAccount, shares);
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
    } else {
      LiquidateVars memory v;
      (v.seizeAssets, v.fixedAssets, v.floatingAssets) = previewLiquidateAssets(market, collateralMarket, BOB);

      if (
        collateralMarket.floatingBackupBorrowed() + collateralMarket.totalFloatingBorrowAssets() >
        collateralMarket.floatingAssets() - v.seizeAssets
      ) {
        vm.expectRevert(InsufficientProtocolLiquidity.selector);
      } else if (
        !moreCollateral(collateralMarket, v.seizeAssets, BOB) &&
        floatingAssetsUnderflow(market, collateralMarket, v.seizeAssets, v.fixedAssets, v.floatingAssets, BOB)
      ) {
        vm.expectRevert(stdError.arithmeticError);
      } else {
        vm.expectEmit(true, true, true, false, address(market));
        emit Liquidate(ALICE, BOB, 0, 0, collateralMarket, 0);
      }
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

  function checkInvariants() internal {
    for (uint256 i = 0; i < accounts.length; ++i) {
      address account = accounts[i];
      if (auditor.accountMarkets(account) == 0) {
        for (uint256 j = 0; j < MARKET_COUNT; ++j) {
          assertEq(markets[j].previewDebt(account), 0, "should contain no debt");
        }
      }
    }
    for (uint256 i = 0; i < auditor.allMarkets().length; ++i) {
      Market market = auditor.marketList(i);
      uint256 fixedBorrows = 0;
      uint256 fixedDeposits = 0;
      for (uint256 j = 0; j < accounts.length; ++j) {
        address account = accounts[j];
        uint256 packedMaturities = market.fixedBorrows(account);
        uint256 baseMaturity = packedMaturities % (1 << 32);
        packedMaturities = packedMaturities >> 32;
        for (uint256 k = 0; k < 224; ++k) {
          if ((packedMaturities & (1 << k)) != 0) {
            uint256 maturity = baseMaturity + (k * FixedLib.INTERVAL);
            (uint256 principal, uint256 fee) = market.fixedBorrowPositions(maturity, account);
            fixedBorrows += principal + fee;
          }
          if ((1 << k) > packedMaturities) break;
        }
        packedMaturities = market.fixedDeposits(account);
        baseMaturity = packedMaturities % (1 << 32);
        packedMaturities = packedMaturities >> 32;
        for (uint256 k = 0; k < 224; ++k) {
          if ((packedMaturities & (1 << k)) != 0) {
            uint256 maturity = baseMaturity + (k * FixedLib.INTERVAL);
            (uint256 principal, uint256 fee) = market.fixedDepositPositions(maturity, account);
            fixedDeposits += principal + fee;
          }
          if ((1 << k) > packedMaturities) break;
        }
      }
      uint256 fixedUnassignedEarnings = 0;
      uint256 floatingBackupBorrowed = 0;
      uint256 backupEarnings = 0;
      uint256 latestMaturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL);
      uint256 maxMaturity = latestMaturity + market.maxFuturePools() * FixedLib.INTERVAL;
      for (uint256 maturity = latestMaturity; maturity <= maxMaturity; maturity += FixedLib.INTERVAL) {
        (uint256 borrowed, uint256 supplied, uint256 unassignedEarnings, uint256 lastAccrual) = market.fixedPools(
          maturity
        );
        floatingBackupBorrowed += borrowed - Math.min(supplied, borrowed);
        // check the totalAssets against the real totalAssets()
        if (maturity > lastAccrual) {
          backupEarnings += block.timestamp < maturity
            ? unassignedEarnings.mulDivDown(block.timestamp - lastAccrual, maturity - lastAccrual)
            : unassignedEarnings;
        }
        fixedUnassignedEarnings += unassignedEarnings;
      }
      uint256 totalAssets = market.floatingAssets() +
        backupEarnings +
        previewAccumulatedEarnings(market) +
        market.totalFloatingBorrowAssets() -
        market.floatingDebt();
      uint256 assets = market.floatingAssets() -
        market.floatingDebt() +
        market.earningsAccumulator() +
        fixedUnassignedEarnings +
        fixedDeposits -
        fixedBorrows;

      assertEq(floatingBackupBorrowed, market.floatingBackupBorrowed());
      assertEq(totalAssets, market.totalAssets());
      assertEq(assets, market.asset().balanceOf(address(market)));
    }
  }

  function floatingAssetsUnderflow(
    Market repaidMarket,
    Market collateralMarket,
    uint256 seizeAssets,
    uint256 fixedRepaidAssets,
    uint256 floatingRepaidAssets,
    address account
  ) internal returns (bool) {
    for (uint256 i = 0; i < auditor.allMarkets().length; ++i) {
      Market market = auditor.marketList(i);
      uint256 floatingAssets = market.floatingAssets();
      uint256 earningsAccumulator = market.earningsAccumulator();
      uint256 debt;
      {
        uint256 packedMaturities = market.fixedBorrows(account);
        uint256 baseMaturity = packedMaturities % (1 << 32);
        packedMaturities = packedMaturities >> 32;
        for (uint256 j = 0; j < 224; ++j) {
          if ((packedMaturities & (1 << j)) != 0) {
            FixedLib.Position memory position;
            (position.principal, position.fee) = market.fixedBorrowPositions(
              baseMaturity + (j * FixedLib.INTERVAL),
              account
            );
            debt += position.principal + position.fee;
          }
          if ((1 << j) > packedMaturities) break;
        }
      }
      if (repaidMarket == market) debt -= fixedRepaidAssets;
      if (collateralMarket == market) floatingAssets -= seizeAssets;

      uint256 fromAccumulator = Math.min(earningsAccumulator, debt);
      earningsAccumulator = earningsAccumulator - fromAccumulator;

      if (fromAccumulator < debt) {
        if (debt - fromAccumulator > floatingAssets) {
          return true;
        }
        floatingAssets -= debt - fromAccumulator;
      }
      if (market.floatingBorrowShares(account) > 0) {
        debt = market.previewRefund(market.floatingBorrowShares(account));
        if (repaidMarket == market) debt -= floatingRepaidAssets;
        fromAccumulator = Math.min(earningsAccumulator, debt);
        earningsAccumulator = earningsAccumulator - fromAccumulator;
        if (fromAccumulator < debt) {
          if (debt - fromAccumulator > floatingAssets) {
            return true;
          }
        }
      }
    }
    return false;
  }

  function moreCollateral(
    Market collateralMarket,
    uint256 seizeAssets,
    address account
  ) internal view returns (bool) {
    uint256 marketMap = auditor.accountMarkets(account);
    for (uint256 i = 0; i < auditor.allMarkets().length; ++i) {
      if ((marketMap & (1 << i)) != 0) {
        Market market = auditor.marketList(i);
        (uint128 adjustFactor, uint8 decimals, , ) = auditor.markets(market);
        uint256 assets = market.maxWithdraw(account);
        if (market == collateralMarket) assets -= seizeAssets;
        if (assets.mulDivDown(oracle.assetPrice(market), 10**decimals).mulWadDown(adjustFactor) > 0) return true;
      }
    }
    return false;
  }

  function previewLiquidateAssets(
    Market market,
    Market collateralMarket,
    address account
  )
    internal
    view
    returns (
      uint256 seizeAssets,
      uint256 fixedAssets,
      uint256 floatingAssets
    )
  {
    uint256 maxAssets = auditor.checkLiquidation(market, collateralMarket, BOB, type(uint256).max);
    uint256 packedMaturities = market.fixedBorrows(account);
    uint256 baseMaturity = packedMaturities % (1 << 32);
    packedMaturities = packedMaturities >> 32;
    for (uint256 i = 0; i < 224; ++i) {
      if ((packedMaturities & (1 << i)) != 0) {
        uint256 maturity = baseMaturity + (i * FixedLib.INTERVAL);
        uint256 actualRepay;
        FixedLib.Position memory p;
        (p.principal, p.fee) = market.fixedBorrowPositions(maturity, account);
        if (block.timestamp < maturity) {
          actualRepay = Math.min(maxAssets, p.principal + p.fee);
          maxAssets -= actualRepay;
        } else {
          uint256 position = p.principal + p.fee;
          uint256 debt = position + position.mulWadDown((block.timestamp - maturity) * market.penaltyRate());
          actualRepay = debt > maxAssets ? maxAssets.mulDivDown(position, debt) : maxAssets;
          if (actualRepay == 0) maxAssets = 0;
          else {
            actualRepay =
              Math.min(actualRepay, position) +
              Math.min(actualRepay, position).mulWadDown((block.timestamp - maturity) * market.penaltyRate());
            maxAssets -= actualRepay;
            debt = position + position.mulWadDown((block.timestamp - maturity) * market.penaltyRate());
            if ((debt > maxAssets ? maxAssets.mulDivDown(position, debt) : maxAssets) == 0) maxAssets = 0;
          }
        }
        fixedAssets += actualRepay;
      }
      if ((1 << i) > packedMaturities || maxAssets == 0) break;
    }
    uint256 shares = market.floatingBorrowShares(account);
    if (maxAssets > 0 && shares > 0) {
      uint256 borrowShares = market.previewRepay(maxAssets);
      if (borrowShares > 0) {
        borrowShares = Math.min(borrowShares, shares);
        floatingAssets += market.previewRefund(borrowShares);
      }
    }
    (, seizeAssets) = auditor.calculateSeize(market, collateralMarket, account, fixedAssets + floatingAssets);
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
    uint256 borrowAssets,
    uint256 withdrawAssets
  ) internal view returns (uint256 sumCollateral, uint256 sumDebtPlusEffects) {
    Auditor.AccountLiquidity memory vars; // holds all our calculation results

    uint256 marketMap = auditor.accountMarkets(account);
    // if simulating a borrow, add the market to the account's map
    if (borrowAssets > 0) {
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
        sumDebtPlusEffects += (vars.borrowBalance + (market == marketToSimulate ? borrowAssets : 0))
          .mulDivUp(vars.oraclePrice, 10**decimals)
          .divWadUp(adjustFactor);
        if (market == marketToSimulate && withdrawAssets != 0) {
          sumDebtPlusEffects += withdrawAssets.mulDivDown(vars.oraclePrice, 10**decimals).mulWadDown(adjustFactor);
        }
      }
      if ((1 << i) > marketMap) break;
    }
  }

  function previewAccountLiquidity(
    address account,
    Market marketToSimulate,
    uint256 borrowAssets,
    uint256 borrowShares
  ) internal view returns (uint256 sumCollateral, uint256 sumDebtPlusEffects) {
    Auditor.AccountLiquidity memory vars; // holds all our calculation results

    uint256 marketMap = auditor.accountMarkets(account);
    // if simulating a borrow, add the market to the account's map
    if (borrowAssets > 0) {
      (, , uint256 index, ) = auditor.markets(marketToSimulate);
      if ((marketMap & (1 << index)) == 0) marketMap = marketMap | (1 << index);
    }
    for (uint256 i = 0; i < auditor.allMarkets().length; ++i) {
      Market market = auditor.marketList(i);
      if ((marketMap & (1 << i)) != 0) {
        (uint128 adjustFactor, uint8 decimals, , ) = auditor.markets(market);
        if (market == marketToSimulate) {
          (vars.balance, vars.borrowBalance) = previewAccountSnapshot(market, account, borrowAssets, borrowShares);
        } else (vars.balance, vars.borrowBalance) = market.accountSnapshot(account);
        vars.oraclePrice = oracle.assetPrice(market);
        sumCollateral += vars.balance.mulDivDown(vars.oraclePrice, 10**decimals).mulWadDown(adjustFactor);
        sumDebtPlusEffects += vars.borrowBalance.mulDivUp(vars.oraclePrice, 10**decimals).divWadUp(adjustFactor);
      }
      if ((1 << i) > marketMap) break;
    }
  }

  function previewAccountSnapshot(
    Market market,
    address account,
    uint256 borrowAssets,
    uint256 borrowShares
  ) internal view returns (uint256, uint256) {
    return (previewConvertToAssets(market, account), previewDebt(market, account, borrowAssets, borrowShares));
  }

  function previewConvertToAssets(Market market, address account) internal view returns (uint256) {
    uint256 supply = market.totalSupply();
    uint256 shares = market.balanceOf(account);
    return supply == 0 ? shares : shares.mulDivDown(previewTotalAssets(market), supply);
  }

  function previewTotalAssets(Market market) internal view returns (uint256) {
    uint256 memMaxFuturePools = market.maxFuturePools();
    uint256 backupEarnings = 0;
    uint256 latestMaturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL);
    uint256 maxMaturity = latestMaturity + memMaxFuturePools * FixedLib.INTERVAL;
    for (uint256 maturity = latestMaturity; maturity <= maxMaturity; maturity += FixedLib.INTERVAL) {
      (, , uint256 unassignedEarnings, uint256 lastAccrual) = market.fixedPools(maturity);

      if (maturity > lastAccrual) {
        backupEarnings += block.timestamp < maturity
          ? unassignedEarnings.mulDivDown(block.timestamp - lastAccrual, maturity - lastAccrual)
          : unassignedEarnings;
      }
    }
    return
      market.floatingAssets() +
      backupEarnings +
      previewAccumulatedEarnings(market) +
      previewTotalFloatingBorrowAssets(market) -
      market.floatingDebt();
  }

  function previewDebt(
    Market market,
    address account,
    uint256 borrowAssets,
    uint256 borrowShares
  ) internal view returns (uint256 debt) {
    uint256 memPenaltyRate = market.penaltyRate();
    uint256 packedMaturities = market.fixedBorrows(account);
    uint256 baseMaturity = packedMaturities % (1 << 32);
    packedMaturities = packedMaturities >> 32;
    for (uint256 i = 0; i < 224; ++i) {
      if ((packedMaturities & (1 << i)) != 0) {
        uint256 maturity = baseMaturity + (i * FixedLib.INTERVAL);
        (uint256 principal, uint256 fee) = market.fixedBorrowPositions(maturity, account);
        uint256 positionAssets = principal + fee;

        debt += positionAssets;

        uint256 secondsDelayed = FixedLib.secondsPre(maturity, block.timestamp);
        if (secondsDelayed > 0) debt += positionAssets.mulWadDown(secondsDelayed * memPenaltyRate);
      }
      if ((1 << i) > packedMaturities) break;
    }
    uint256 shares = market.floatingBorrowShares(account);
    if (shares + borrowShares > 0) debt += previewRefund(market, shares, borrowAssets, borrowShares);
  }

  function previewRefund(
    Market market,
    uint256 shares,
    uint256 borrowAssets,
    uint256 borrowShares
  ) internal view returns (uint256) {
    uint256 supply = market.totalFloatingBorrowShares() + borrowShares;
    shares += borrowShares;
    return supply == 0 ? shares : shares.mulDivUp(previewTotalFloatingBorrowAssets(market) + borrowAssets, supply);
  }

  function previewTotalFloatingBorrowAssets(Market market) internal view returns (uint256) {
    uint256 memFloatingAssets = market.floatingAssets();
    uint256 memFloatingDebt = market.floatingDebt();
    uint256 newFloatingUtilization = memFloatingAssets > 0
      ? Math.min(memFloatingDebt.divWadUp(memFloatingAssets), 1e18)
      : 0;
    uint256 newDebt = memFloatingDebt.mulWadDown(
      market.interestRateModel().floatingBorrowRate(market.floatingUtilization(), newFloatingUtilization).mulDivDown(
        block.timestamp - market.lastFloatingDebtUpdate(),
        365 days
      )
    );
    return memFloatingDebt + newDebt;
  }

  function previewDepositYield(
    Market market,
    uint256 maturity,
    uint256 amount
  ) internal view returns (uint256 yield) {
    (uint256 borrowed, uint256 supplied, uint256 unassignedEarnings, uint256 lastAccrual) = market.fixedPools(maturity);
    uint256 memBackupSupplied = borrowed - Math.min(borrowed, supplied);
    if (memBackupSupplied != 0) {
      uint256 secondsSinceLastAccrue = FixedLib.secondsPre(lastAccrual, Math.min(maturity, block.timestamp));
      uint256 secondsTotalToMaturity = FixedLib.secondsPre(lastAccrual, maturity);
      unassignedEarnings -= unassignedEarnings.mulDivDown(secondsSinceLastAccrue, secondsTotalToMaturity);
      yield = unassignedEarnings.mulDivDown(Math.min(amount, memBackupSupplied), memBackupSupplied);
      uint256 backupFee = yield.mulWadDown(market.backupFeeRate());
      yield -= backupFee;
    }
  }

  function previewNewFloatingDebt(Market market) internal view returns (uint256) {
    InterestRateModel memIRM = market.interestRateModel();
    uint256 memFloatingDebt = market.floatingDebt();
    uint256 memFloatingAssets = market.floatingAssets();
    uint256 newFloatingUtilization = memFloatingAssets > 0
      ? Math.min(memFloatingDebt.divWadUp(memFloatingAssets), 1e18)
      : 0;
    return
      memFloatingDebt.mulWadDown(
        memIRM.floatingBorrowRate(market.floatingUtilization(), newFloatingUtilization).mulDivDown(
          block.timestamp - market.lastFloatingDebtUpdate(),
          365 days
        )
      );
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

  function previewFloatingAssetsAverage(Market market) internal view returns (uint256) {
    uint256 floatingDepositAssets = market.floatingAssets();
    uint256 floatingAssetsAverage = market.floatingAssetsAverage();
    uint256 dampSpeedFactor = floatingDepositAssets < floatingAssetsAverage
      ? market.dampSpeedDown()
      : market.dampSpeedUp();
    uint256 averageFactor = uint256(
      1e18 - (-int256(dampSpeedFactor * (block.timestamp - market.lastAverageUpdate()))).expWad()
    );

    return floatingAssetsAverage.mulWadDown(1e18 - averageFactor) + averageFactor.mulWadDown(floatingDepositAssets);
  }

  struct LiquidateVars {
    uint256 seizeAssets;
    uint256 fixedAssets;
    uint256 floatingAssets;
  }

  event Transfer(address indexed from, address indexed to, uint256 amount);
  event MarketExited(Market indexed market, address indexed account);
  event MarketEntered(Market indexed market, address indexed account);
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
  event DepositAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed owner,
    uint256 assets,
    uint256 fee
  );
  event WithdrawAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed owner,
    uint256 assets,
    uint256 assetsDiscounted
  );
  event RepayAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed borrower,
    uint256 assets,
    uint256 positionAssets
  );
  event BorrowAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 fee
  );
}
