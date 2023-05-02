// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { LibString } from "solmate/src/utils/LibString.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import {
  Market,
  InsufficientProtocolLiquidity,
  SelfLiquidation,
  ZeroBorrow,
  ZeroDeposit,
  ZeroRepay,
  ZeroWithdraw
} from "../../contracts/Market.sol";
import { InterestRateModel, UtilizationExceeded } from "../../contracts/InterestRateModel.sol";
import { MockPriceFeed } from "../../contracts/mocks/MockPriceFeed.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";
import {
  Auditor,
  IPriceFeed,
  AuditorMismatch,
  InsufficientAccountLiquidity,
  InsufficientShortfall,
  MarketAlreadyListed,
  RemainingDebt
} from "../../contracts/Auditor.sol";
import { RewardsController } from "../../contracts/RewardsController.sol";

contract ProtocolTest is Test {
  using FixedPointMathLib for int256;
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;
  using FixedPointMathLib for uint96;
  using FixedPointMathLib for uint64;
  using LibString for uint256;
  using FixedLib for FixedLib.Position;

  address[] internal accounts;
  Auditor internal auditor;
  Market[] internal markets;
  RewardsController internal rewardsController;

  MockERC20 internal rewardAsset;
  uint256 internal claimedRewards;
  mapping(Market => uint256) internal shareValues;
  mapping(Market => uint256) internal newAccumulatedEarnings;

  function setUp() external {
    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    vm.label(address(auditor), "Auditor");
    InterestRateModel irm = new InterestRateModel(0.023e18, -0.0025e18, 1.02e18, 0.023e18, -0.0025e18, 1.02e18);

    for (uint256 i = 0; i < 2; ++i) {
      address account = address(uint160((i + 1) * (uint256(type(uint152).max) + 1)));
      vm.label(address(account), string.concat("account", (i + 1).toString()));
      targetSender(account);
      accounts.push(account);
    }

    for (uint256 i = 0; i < 2; ++i) {
      string memory symbol = string(abi.encodePacked(uint8(i) + 65));
      MockERC20 asset = new MockERC20(symbol, symbol, 18);
      vm.label(address(asset), symbol);
      Market market = Market(address(new ERC1967Proxy(address(new Market(asset, auditor)), "")));
      market.initialize(3, 2e18, irm, 0.02e18 / uint256(1 days), 1e17, 1e17, 0.0046e18, 0.42e18);
      vm.label(address(market), market.symbol());
      MockPriceFeed priceFeed = new MockPriceFeed(18, 1e18);
      // market.setTreasury(address(this), 0.1e18);
      auditor.enableMarket(market, priceFeed, 0.9e18);

      asset.approve(address(market), type(uint256).max);
      for (uint256 j = 0; j < accounts.length; ++j) {
        vm.prank(accounts[j]);
        asset.approve(address(market), type(uint256).max);
      }
      markets.push(market);
    }

    rewardsController = RewardsController(address(new ERC1967Proxy(address(new RewardsController()), "")));
    rewardsController.initialize();
    vm.label(address(rewardsController), "RewardsController");
    rewardAsset = new MockERC20("OP", "OP", 18);
    rewardAsset.mint(address(rewardsController), 2_000 ether);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: markets[0],
      reward: rewardAsset,
      targetDebt: 20_000 ether,
      priceFeed: MockPriceFeed(address(0)),
      totalDistribution: 2_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 4 weeks,
      undistributedFactor: 0.5e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    markets[0].setRewardsController(rewardsController);

    targetContract(address(this));
    bytes4[] memory selectors = new bytes4[](17);
    selectors[0] = this.enterMarket.selector;
    selectors[1] = this.exitMarket.selector;
    selectors[2] = this.deposit.selector;
    selectors[3] = this.mint.selector;
    selectors[4] = this.withdraw.selector;
    selectors[5] = this.redeem.selector;
    selectors[6] = this.transfer.selector;
    selectors[7] = this.borrow.selector;
    selectors[8] = this.repay.selector;
    selectors[9] = this.refund.selector;
    selectors[10] = this.depositAtMaturity.selector;
    selectors[11] = this.withdrawAtMaturity.selector;
    selectors[12] = this.borrowAtMaturity.selector;
    selectors[13] = this.repayAtMaturity.selector;
    selectors[14] = this.claimRewards.selector;
    selectors[15] = this.setPrice.selector;
    selectors[16] = this.liquidate.selector;
    targetSelector(FuzzSelector(address(this), selectors));
  }

  function invariants() external {
    for (uint256 i = 0; i < accounts.length; ++i) {
      address account = accounts[i];
      if (auditor.accountMarkets(account) == 0) {
        for (uint256 j = 0; j < markets.length; ++j) {
          assertEq(markets[j].previewDebt(account), 0, "should contain no debt");
        }
      }
      for (uint256 j = 0; j < markets.length; ++j) {
        (, uint256 packedMaturities, ) = markets[j].accounts(account);
        uint256 maturity = packedMaturities & ((1 << 32) - 1);
        packedMaturities = packedMaturities >> 32;
        while (packedMaturities != 0) {
          if (packedMaturities & 1 != 0) {
            FixedLib.Position memory p;
            (p.principal, p.fee) = markets[j].fixedBorrowPositions(maturity, account);
            assertGt(p.principal + p.fee, 0, "should contain debt");
          }
          packedMaturities >>= 1;
          maturity += FixedLib.INTERVAL;
        }
        (packedMaturities, , ) = markets[j].accounts(account);
        maturity = packedMaturities & ((1 << 32) - 1);
        packedMaturities = packedMaturities >> 32;
        while (packedMaturities != 0) {
          if (packedMaturities & 1 != 0) {
            FixedLib.Position memory p;
            (p.principal, p.fee) = markets[j].fixedDepositPositions(maturity, account);
            assertGt(p.principal + p.fee, 0, "should contain deposit");
          }
          packedMaturities >>= 1;
          maturity += FixedLib.INTERVAL;
        }
      }
    }
    for (uint256 i = 0; i < auditor.allMarkets().length; ++i) {
      Market market = auditor.marketList(i);
      uint256 fixedBorrows = 0;
      uint256 fixedDeposits = 0;
      for (uint256 j = 0; j < accounts.length; ++j) {
        address account = accounts[j];
        (, uint256 packedMaturities, ) = market.accounts(account);
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
        (packedMaturities, , ) = market.accounts(account);
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
      uint256 maxMaturity = block.timestamp -
        (block.timestamp % FixedLib.INTERVAL) +
        market.maxFuturePools() *
        FixedLib.INTERVAL;
      for (uint256 maturity = 0; maturity <= maxMaturity; maturity += FixedLib.INTERVAL) {
        (uint256 borrowed, uint256 supplied, uint256 unassignedEarnings, uint256 lastAccrual) = market.fixedPools(
          maturity
        );
        floatingBackupBorrowed += borrowed - Math.min(supplied, borrowed);
        // check the totalAssets against the real totalAssets()
        if (maturity > lastAccrual && maturity >= latestMaturity) {
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

      assertEq(floatingBackupBorrowed, market.floatingBackupBorrowed(), "should match floatingBackupBorrowed");
      assertEq(totalAssets, market.totalAssets(), "should match totalAssets()");
      assertEq(assets, market.asset().balanceOf(address(market)), "should match underlying balance");
    }
    (uint256 start, uint256 end, uint256 lastUpdate) = rewardsController.distributionTime(markets[0], rewardAsset);
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(markets[0], rewardAsset);
    RewardsController.Config memory config = rewardsController.rewardConfig(markets[0], rewardAsset);
    uint256 releaseRate = config.totalDistribution.mulWadDown(1e18 / config.distributionPeriod);
    assertApproxEqAbs(
      claimedRewards + lastUndistributed,
      releaseRate * Math.min(lastUpdate - start, config.distributionPeriod),
      1e14
    );
    assertApproxEqAbs(
      lastUndistributed + releaseRate * (end - Math.min(lastUpdate, end)),
      config.totalDistribution - claimedRewards,
      1e14
    );
  }

  function invariantShareValue() external {
    for (uint256 i = 0; i < markets.length; ++i) {
      Market market = markets[i];
      if (market.totalSupply() > 0) {
        assertGe(market.previewMint(1e18), shareValues[market]);
        shareValues[market] = market.previewMint(1e18);
      }
    }
  }

  function invariantTotalSupply() external {
    for (uint i = 0; i < markets.length; i++) {
      Market market = markets[i];
      uint256 sum;
      for (uint j = 0; j < accounts.length; j++) {
        sum += market.balanceOf(accounts[j]);
      }
      assertEq(sum, market.totalSupply());
    }
  }

  function invariantReserveFactor() external {
    for (uint i = 0; i < markets.length; i++) {
      Market market = markets[i];
      assertLe(market.floatingDebt(), market.floatingAssets().mulWadDown(1e18 - market.reserveFactor()));
    }
  }

  function invariantAssetTransfer() external view {
    for (uint i = 0; i < accounts.length; i++) {
      for (uint j = 0; j < markets.length; j++) {
        Market market = markets[j];
        MockERC20 asset = MockERC20(address(market.asset()));
        assert(asset.balanceOf(accounts[i]) == 0);
      }
    }
  }

  function depositAtMaturity(uint8 seed, uint96 assets) external context(seed) {
    if (assets == 0) {
      vm.expectRevert(ZeroDeposit.selector);
    } else {
      _asset.mint(msg.sender, assets);
      vm.expectEmit(true, true, true, true, address(_market));
      emit DepositAtMaturity(_maturity, msg.sender, msg.sender, assets, 0);
    }
    _market.depositAtMaturity(_maturity, assets, 0, msg.sender);
  }

  function withdrawAtMaturity(uint8 seed, uint96 assets) external context(seed) {
    (uint256 borrowed, uint256 supplied, , ) = _market.fixedPools(_maturity);
    (uint256 principal, uint256 fee) = _market.fixedDepositPositions(_maturity, msg.sender);
    uint256 positionAssets = assets > principal + fee ? principal + fee : assets;
    uint256 backupAssets = previewFloatingAssetsAverage(_market);
    uint256 assetsDiscounted;

    if (assets == 0) {
      vm.expectRevert(ZeroWithdraw.selector);
    } else if (block.timestamp < _maturity && supplied + backupAssets == 0) {
      vm.expectRevert(bytes(""));
    } else if (
      (block.timestamp < _maturity && positionAssets > backupAssets + supplied) ||
      (borrowed + positionAssets).divWadUp(backupAssets + supplied) > 1e18
    ) {
      vm.expectRevert(UtilizationExceeded.selector);
    } else if (
      block.timestamp < _maturity && ((supplied + previewFloatingAssetsAverage(_market) == 0) || principal + fee == 0)
    ) {
      vm.expectRevert(bytes(""));
    } else if (
      _market.floatingBackupBorrowed() +
        Math.min(supplied, borrowed) -
        Math.min(supplied - FixedLib.Position(principal, fee).scaleProportionally(positionAssets).principal, borrowed) +
        _market.totalFloatingBorrowAssets() >
      _market.floatingAssets() + previewNewFloatingDebt(_market)
    ) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else {
      assetsDiscounted = block.timestamp < _maturity
        ? positionAssets.divWadDown(
          1e18 +
            _market.interestRateModel().fixedBorrowRate(_maturity, positionAssets, borrowed, supplied, backupAssets)
        )
        : positionAssets;
      if (assetsDiscounted > _asset.balanceOf(address(_market))) {
        vm.expectRevert(bytes(""));
      } else {
        vm.expectEmit(true, true, true, true, address(_market));
        emit WithdrawAtMaturity(_maturity, msg.sender, msg.sender, msg.sender, positionAssets, assetsDiscounted);
      }
    }
    assetsDiscounted = _market.withdrawAtMaturity(_maturity, assets, 0, msg.sender, msg.sender);
    if (assetsDiscounted > 0) _asset.burn(msg.sender, assetsDiscounted);
  }

  function repayAtMaturity(uint8 seed, uint96 assets) external context(seed) {
    (uint256 principal, uint256 fee) = _market.fixedBorrowPositions(_maturity, msg.sender);
    uint256 positionAssets = assets > principal + fee ? principal + fee : assets;

    if (positionAssets == 0) {
      vm.expectRevert(ZeroRepay.selector);
    } else {
      uint256 yield = block.timestamp < _maturity
        ? previewDepositYield(
          _market,
          _maturity,
          FixedLib.Position(principal, fee).scaleProportionally(positionAssets).principal
        )
        : 0;
      if (positionAssets < yield) {
        vm.expectRevert(stdError.arithmeticError);
      } else {
        uint256 actualRepayAssets = block.timestamp < _maturity
          ? positionAssets - yield
          : (positionAssets + positionAssets.mulWadDown((block.timestamp - _maturity) * _market.penaltyRate()));
        _asset.mint(msg.sender, actualRepayAssets);

        vm.expectEmit(true, true, true, true, address(_market));
        emit RepayAtMaturity(_maturity, msg.sender, msg.sender, actualRepayAssets, positionAssets);
      }
    }
    _market.repayAtMaturity(_maturity, positionAssets, type(uint256).max, msg.sender);
  }

  function borrowAtMaturity(uint8 seed, uint96 assets) external context(seed) {
    (uint256 borrowed, uint256 supplied, , ) = _market.fixedPools(_maturity);
    uint256 backupAssets = previewFloatingAssetsAverage(_market);
    uint256 backupDebtAddition;
    {
      uint256 newBorrowed = borrowed + assets;
      backupDebtAddition = newBorrowed - Math.min(Math.max(borrowed, supplied), newBorrowed);
    }

    if (assets == 0) {
      vm.expectRevert(ZeroBorrow.selector);
    } else if (supplied + backupAssets == 0) {
      vm.expectRevert(bytes(""));
    } else if (assets > backupAssets + supplied || (borrowed + assets).divWadUp(backupAssets + supplied) > 1e18) {
      vm.expectRevert(UtilizationExceeded.selector);
    } else if (
      backupDebtAddition > 0 &&
      _market.floatingBackupBorrowed() + backupDebtAddition + _market.totalFloatingBorrowAssets() >
      (_market.floatingAssets() + previewNewFloatingDebt(_market)).mulWadDown(1e18 - _market.reserveFactor())
    ) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else {
      uint256 fees = assets.mulWadDown(
        _market.interestRateModel().fixedBorrowRate(_maturity, assets, borrowed, supplied, backupAssets)
      );
      newAccumulatedEarnings[_market] = fees.mulDivDown(
        assets - Math.min(borrowed + assets - Math.min(borrowed + assets, supplied), assets),
        assets
      );
      (uint256 collateral, uint256 debt) = accountLiquidity(msg.sender, _market, assets + fees, 0);
      newAccumulatedEarnings[_market] = 0;
      if (collateral < debt) {
        vm.expectRevert(InsufficientAccountLiquidity.selector);
      } else if (assets > _asset.balanceOf(address(_market))) {
        vm.expectRevert(bytes(""));
      } else {
        vm.expectEmit(true, true, true, true, address(_market));
        emit BorrowAtMaturity(_maturity, msg.sender, msg.sender, msg.sender, assets, fees);
      }
    }
    uint256 assetsOwed = _market.borrowAtMaturity(_maturity, assets, type(uint256).max, msg.sender, msg.sender);
    if (assetsOwed > 0) _asset.burn(msg.sender, assets);
  }

  function deposit(uint8 seed, uint96 assets) external context(seed) {
    uint256 expectedShares = _market.convertToShares(assets);

    if (expectedShares == 0) {
      vm.expectRevert(bytes(""));
    } else {
      _asset.mint(msg.sender, assets);
      vm.expectEmit(true, true, true, true, address(_market));
      emit Deposit(msg.sender, msg.sender, assets, expectedShares);
    }
    _market.deposit(assets, msg.sender);
  }

  function mint(uint8 seed, uint96 shares) external context(seed) {
    uint256 expectedAssets = _market.previewMint(shares);
    _asset.mint(msg.sender, expectedAssets);

    vm.expectEmit(true, true, true, true, address(_market));
    emit Deposit(msg.sender, msg.sender, expectedAssets, shares);
    _market.mint(shares, msg.sender);
  }

  function claimRewards(uint8 seed) external context(seed) {
    uint256 accumulatedRewards = rewardsController.allClaimable(msg.sender, rewardAsset);
    uint256 balanceBefore = rewardAsset.balanceOf(msg.sender);
    rewardsController.claimAll(msg.sender);
    assertEq(rewardAsset.balanceOf(msg.sender), balanceBefore + accumulatedRewards);
    claimedRewards += accumulatedRewards;
  }

  function enterMarket(uint8 seed) external context(seed) {
    (, , uint256 index, , ) = auditor.markets(_market);

    if ((auditor.accountMarkets(msg.sender) & (1 << index)) == 0) {
      vm.expectEmit(true, true, true, true, address(auditor));
      emit MarketEntered(_market, msg.sender);
    }
    auditor.enterMarket(_market);
  }

  function exitMarket(uint8 seed) external context(seed) {
    (, , uint256 index, , ) = auditor.markets(_market);
    (uint256 balance, uint256 debt) = _market.accountSnapshot(msg.sender);
    (uint256 adjustedCollateral, uint256 adjustedDebt) = accountLiquidity(msg.sender, _market, 0, balance);
    uint256 marketMap = auditor.accountMarkets(msg.sender);

    if ((marketMap & (1 << index)) != 0) {
      if (debt > 0) {
        vm.expectRevert(RemainingDebt.selector);
      } else if (adjustedCollateral < adjustedDebt) {
        vm.expectRevert(InsufficientAccountLiquidity.selector);
      } else {
        vm.expectEmit(true, true, true, true, address(auditor));
        emit MarketExited(_market, msg.sender);
      }
    }
    auditor.exitMarket(_market);
    if ((marketMap & (1 << index)) == 0) assertEq(marketMap, auditor.accountMarkets(msg.sender));
  }

  function borrow(uint8 seed, uint96 assets) external context(seed) {
    uint256 expectedShares = _market.previewBorrow(assets);
    (uint256 collateral, uint256 debt) = previewAccountLiquidity(msg.sender, _market, assets, expectedShares);

    if (
      _market.floatingBackupBorrowed() + _market.totalFloatingBorrowAssets() + assets >
      (_market.floatingAssets() + previewNewFloatingDebt(_market)).mulWadDown(1e18 - _market.reserveFactor())
    ) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else if (debt > collateral) {
      vm.expectRevert(InsufficientAccountLiquidity.selector);
    } else if (assets > _asset.balanceOf(address(_market))) {
      vm.expectRevert(bytes(""));
    } else {
      vm.expectEmit(true, true, true, true, address(_market));
      emit Borrow(msg.sender, msg.sender, msg.sender, assets, expectedShares);
    }
    uint256 borrowShares = _market.borrow(assets, msg.sender, msg.sender);
    if (borrowShares > 0) _asset.burn(msg.sender, assets);
  }

  function repay(uint8 seed, uint96 assets) external context(seed) {
    (, , uint256 floatingBorrowShares) = _market.accounts(msg.sender);
    uint256 borrowShares = Math.min(_market.previewRepay(assets), floatingBorrowShares);
    uint256 refundAssets = _market.previewRefund(borrowShares);

    if (refundAssets == 0) {
      vm.expectRevert(ZeroRepay.selector);
    } else {
      _asset.mint(msg.sender, refundAssets);
      vm.expectEmit(true, true, true, true, address(_market));
      emit Repay(msg.sender, msg.sender, refundAssets, borrowShares);
    }
    _market.repay(assets, msg.sender);
  }

  function refund(uint8 seed, uint96 shares) external context(seed) {
    (, , uint256 floatingBorrowShares) = _market.accounts(msg.sender);
    uint256 borrowShares = Math.min(shares, floatingBorrowShares);
    uint256 refundAssets = _market.previewRefund(borrowShares);

    if (refundAssets == 0) {
      vm.expectRevert(ZeroRepay.selector);
    } else {
      _asset.mint(msg.sender, refundAssets);
      vm.expectEmit(true, true, true, true, address(_market));
      emit Repay(msg.sender, msg.sender, refundAssets, borrowShares);
    }
    _market.refund(shares, msg.sender);
  }

  function withdraw(uint8 seed, uint96 assets) external context(seed) {
    (, , uint256 index, , ) = auditor.markets(_market);
    uint256 expectedShares = _market.totalAssets() != 0 ? _market.previewWithdraw(assets) : 0;
    (uint256 collateral, uint256 debt) = accountLiquidity(msg.sender, _market, 0, assets);
    uint256 earnings = previewAccumulatedEarnings(_market);

    if ((auditor.accountMarkets(msg.sender) & (1 << index)) != 0 && debt > collateral) {
      vm.expectRevert(InsufficientAccountLiquidity.selector);
    } else if (_market.totalSupply() > 0 && _market.totalAssets() == 0) {
      vm.expectRevert(bytes(""));
    } else if (assets > _market.floatingAssets() + previewNewFloatingDebt(_market) + earnings) {
      vm.expectRevert(stdError.arithmeticError);
    } else if (
      _market.floatingBackupBorrowed() + _market.totalFloatingBorrowAssets() >
      _market.floatingAssets() + previewNewFloatingDebt(_market) + earnings - assets
    ) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else if (expectedShares > _market.balanceOf(msg.sender)) {
      vm.expectRevert(stdError.arithmeticError);
    } else if (assets > _asset.balanceOf(address(_market))) {
      vm.expectRevert(bytes(""));
    } else {
      vm.expectEmit(true, true, true, true, address(_market));
      emit Withdraw(msg.sender, msg.sender, msg.sender, assets, expectedShares);
    }
    uint256 withdrawShares = _market.withdraw(assets, msg.sender, msg.sender);
    if (withdrawShares > 0) _asset.burn(msg.sender, assets);
  }

  function redeem(uint8 seed, uint96 shares) external context(seed) {
    (, , uint256 index, , ) = auditor.markets(_market);
    uint256 expectedAssets = _market.previewRedeem(shares);
    (uint256 collateral, uint256 debt) = accountLiquidity(msg.sender, _market, 0, expectedAssets);
    uint256 earnings = previewAccumulatedEarnings(_market);

    if (expectedAssets == 0 && ((auditor.accountMarkets(msg.sender) & (1 << index)) == 0 || collateral >= debt)) {
      vm.expectRevert(bytes(""));
    } else if ((auditor.accountMarkets(msg.sender) & (1 << index)) != 0 && debt > collateral) {
      vm.expectRevert(InsufficientAccountLiquidity.selector);
    } else if (_market.totalSupply() > 0 && _market.totalAssets() == 0) {
      vm.expectRevert(bytes(""));
    } else if (expectedAssets > _market.floatingAssets() + previewNewFloatingDebt(_market) + earnings) {
      vm.expectRevert(stdError.arithmeticError);
    } else if (
      _market.floatingBackupBorrowed() + _market.totalFloatingBorrowAssets() >
      _market.floatingAssets() + previewNewFloatingDebt(_market) + earnings - expectedAssets
    ) {
      vm.expectRevert(InsufficientProtocolLiquidity.selector);
    } else if (shares > _market.balanceOf(msg.sender)) {
      vm.expectRevert(stdError.arithmeticError);
    } else if (expectedAssets > _asset.balanceOf(address(_market))) {
      vm.expectRevert(bytes(""));
    } else {
      vm.expectEmit(true, true, true, true, address(_market));
      emit Withdraw(msg.sender, msg.sender, msg.sender, expectedAssets, shares);
    }
    expectedAssets = _market.redeem(shares, msg.sender, msg.sender);
    if (expectedAssets > 0) _asset.burn(msg.sender, expectedAssets);
  }

  function transfer(uint8 seed, uint96 shares) external context(seed) {
    (, , uint256 index, , ) = auditor.markets(_market);
    uint256 withdrawAssets = _market.previewRedeem(shares);
    (uint256 collateral, uint256 debt) = accountLiquidity(msg.sender, _market, 0, withdrawAssets);

    if ((auditor.accountMarkets(msg.sender) & (1 << index)) != 0 && debt > collateral) {
      vm.expectRevert(InsufficientAccountLiquidity.selector);
    } else if (shares > _market.balanceOf(msg.sender)) {
      vm.expectRevert(stdError.arithmeticError);
    } else {
      vm.expectEmit(true, true, true, true, address(_market));
      emit Transfer(msg.sender, _counterparty, shares);
    }
    _market.transfer(_counterparty, shares);
  }

  function setPrice(uint8 seed, uint96 price) external context(seed) {
    (, , , , IPriceFeed priceFeed) = auditor.markets(_market);
    MockPriceFeed(address(priceFeed)).setPrice(int256(uint256(_bound(price, 1, type(uint96).max))));
  }

  function liquidate(uint256 seed) external liquidationContext(seed) {
    (, , uint256 index, , ) = auditor.markets(_market);
    (, , uint256 collateralIndex, , ) = auditor.markets(_collateralMarket);
    (uint256 collateral, uint256 debt) = accountLiquidity(_counterparty, Market(address(0)), 0, 0);
    LiquidationVars memory lv;

    if (collateral >= debt) {
      vm.expectRevert(InsufficientShortfall.selector);
    } else if (rawCollateral(_counterparty) == 0) {
      vm.expectRevert(bytes(""));
    } else if (
      (auditor.accountMarkets(_counterparty) & (1 << collateralIndex)) == 0 ||
      seizeAvailable(_counterparty, _collateralMarket) == 0
    ) {
      vm.expectRevert(ZeroRepay.selector);
    } else if ((auditor.accountMarkets(_counterparty) & (1 << index)) == 0) {
      vm.expectRevert(bytes(""));
    } else if (_market.previewDebt(_counterparty) == 0) {
      vm.expectRevert(ZeroWithdraw.selector);
    } else {
      unchecked {
        if (collateral > 0 && (collateral * debt) / collateral != debt) {
          vm.expectRevert(bytes(""));
        } else {
          lv = previewLiquidation(_market, _collateralMarket, _counterparty);
          uint256 earnings = previewAccumulatedEarnings(_collateralMarket);

          if (lv.seizeAssets == 0) {
            vm.expectRevert(ZeroWithdraw.selector);
          } else if (
            lv.seizeAssets > _collateralMarket.floatingAssets() + previewNewFloatingDebt(_collateralMarket) + earnings
          ) {
            vm.expectRevert(stdError.arithmeticError);
          } else {
            if (
              _collateralMarket.floatingBackupBorrowed() +
                _collateralMarket.totalFloatingBorrowAssets() -
                (address(_market) != address(_collateralMarket) ? 0 : lv.debtReduction) >
              _collateralMarket.floatingAssets() + previewNewFloatingDebt(_collateralMarket) + earnings - lv.seizeAssets
            ) {
              vm.expectRevert(InsufficientProtocolLiquidity.selector);
            } else if (lv.seizeAssets > _collateralMarket.asset().balanceOf(address(_collateralMarket))) {
              vm.expectRevert(bytes(""));
            } else {
              _asset.mint(msg.sender, type(uint128).max);
              vm.expectEmit(true, true, true, true, address(_market));
              emit Liquidate(
                msg.sender,
                _counterparty,
                lv.repayAssets,
                lv.lendersAssets,
                _collateralMarket,
                lv.seizeAssets
              );
            }
          }
        }
      }
    }
    uint256 repaidAssets = _market.liquidate(_counterparty, type(uint256).max, _collateralMarket);
    if (repaidAssets > 0) MockERC20(address(_collateralMarket.asset())).burn(msg.sender, lv.seizeAssets);
    _asset.burn(msg.sender, _asset.balanceOf(msg.sender));
  }

  Market internal _market;
  MockERC20 internal _asset;
  uint256 internal _maturity;
  address internal _counterparty;
  modifier context(uint8 seed) {
    assert(address(_market) == address(0));
    _market = markets[_bound(uint256(keccak256(abi.encode(seed, "market"))), 0, markets.length - 1)];
    _asset = MockERC20(address(_market.asset()));
    _maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    _counterparty = accounts[_bound(uint256(keccak256(abi.encode(seed, "counterparty"))), 0, accounts.length - 1)];
    vm.startPrank(msg.sender);
    _;
    vm.stopPrank();
    _market = Market(address(0));
  }

  Market internal _collateralMarket;
  modifier liquidationContext(uint256 seed) {
    assert(address(_market) == address(0));
    _counterparty = accounts[
      (uint8(bytes1(bytes20(msg.sender))) + _bound(seed, 0, accounts.length - 2)) % accounts.length
    ];
    _market = markets[_bound(uint256(keccak256(abi.encode(seed, "market"))), 0, markets.length - 1)];
    _collateralMarket = _market;
    uint256 counterpartyMarkets = auditor.accountMarkets(_counterparty);
    for (uint256 i = 0; counterpartyMarkets != 0; counterpartyMarkets >>= 1) {
      if (counterpartyMarkets & 1 != 0) {
        Market market = auditor.marketList(i);
        (uint256 adjustFactor, , , , ) = auditor.markets(market);
        vm.prank(address(this));
        auditor.setAdjustFactor(market, uint128(adjustFactor.mulWadDown(_bound(seed, 0.1e18, 0.5e18))));
        if (market.previewDebt(_counterparty) > 0) _market = market;
        if (market.balanceOf(_counterparty) > 0) _collateralMarket = market;
      }
    }
    _asset = MockERC20(address(_market.asset()));
    assert(_asset.balanceOf(msg.sender) == 0);
    _maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    vm.startPrank(msg.sender);
    _;
    vm.stopPrank();
    assert(_asset.balanceOf(msg.sender) == 0);

    // bad debt cleared check
    BadDebtVars memory b;
    Auditor.MarketData memory md;
    (md.adjustFactor, md.decimals, , , md.priceFeed) = auditor.markets(_market);
    (b.balance, b.repayMarketDebt) = _market.accountSnapshot(_counterparty);
    b.adjustedCollateral = b.balance.mulDivDown(uint256(md.priceFeed.latestAnswer()), 10 ** md.decimals).mulWadDown(
      md.adjustFactor
    );
    (md.adjustFactor, md.decimals, , , md.priceFeed) = auditor.markets(_collateralMarket);
    (b.balance, b.collateralMarketDebt) = _collateralMarket.accountSnapshot(_counterparty);
    b.adjustedCollateral += b.balance.mulDivDown(uint256(md.priceFeed.latestAnswer()), 10 ** md.decimals).mulWadDown(
      md.adjustFactor
    );

    // if collateral is 0 then debt should be 0
    if (b.adjustedCollateral == 0) {
      if (_market.earningsAccumulator() >= b.repayMarketDebt) {
        assertEq(b.repayMarketDebt, 0, "should have cleared debt");
      }
      if (_collateralMarket.earningsAccumulator() >= b.collateralMarketDebt) {
        assertEq(b.collateralMarketDebt, 0, "should have cleared debt");
      }
    }

    for (uint256 i = 0; i < markets.length; ++i) {
      Market market = markets[i];
      // force earnings to accumulator if assets are 0 and shares are positive
      if (market.totalSupply() > 0 && market.totalAssets() == 0) {
        Market otherMarket = markets[i == 0 ? i + 1 : i - 1];
        MockERC20 asset = MockERC20(address(market.asset()));
        MockERC20 otherAsset = MockERC20(address(otherMarket.asset()));
        address sender = msg.sender;
        vm.stopPrank();
        vm.startPrank(address(0x420));
        asset.mint(msg.sender, type(uint96).max);
        asset.approve(address(market), type(uint256).max);
        otherAsset.mint(msg.sender, type(uint96).max);
        otherAsset.approve(address(otherMarket), type(uint256).max);
        otherMarket.deposit(type(uint96).max, msg.sender);
        auditor.enterMarket(otherMarket);
        FixedLib.Pool memory pool;
        (pool.borrowed, pool.supplied, , ) = market.fixedPools(_maturity);
        market.depositAtMaturity(
          _maturity,
          pool.borrowed - Math.min(pool.borrowed, pool.supplied) + 1_000_000,
          0,
          msg.sender
        );
        market.borrowAtMaturity(_maturity, 1_000_000, type(uint256).max, msg.sender, msg.sender);
        vm.warp(block.timestamp + 1 days);
        vm.stopPrank();
        vm.startPrank(sender);
      }
    }

    _market = Market(address(0));
  }

  function previewLiquidation(
    Market market,
    Market collateralMarket,
    address account
  ) internal view returns (LiquidationVars memory lv) {
    uint256 floatingAssets;
    uint256 fixedAssets;
    uint256 maxAssets = auditor.checkLiquidation(market, collateralMarket, account, type(uint256).max);
    (, uint256 packedMaturities, ) = market.accounts(account);
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
          lv.debtReduction += previewBackupDebtReduction(market, account, maturity, actualRepay);
        } else {
          uint256 position = p.principal + p.fee;
          uint256 debt = position + position.mulWadDown((block.timestamp - maturity) * market.penaltyRate());
          actualRepay = debt > maxAssets ? maxAssets.mulDivDown(position, debt) : maxAssets;
          if (actualRepay == 0) maxAssets = 0;
          else {
            lv.debtReduction += previewBackupDebtReduction(
              market,
              account,
              maturity,
              debt > maxAssets ? maxAssets.mulDivDown(position, debt) : Math.min(maxAssets, p.principal + p.fee)
            );
            actualRepay =
              Math.min(actualRepay, position) +
              Math.min(actualRepay, position).mulWadDown((block.timestamp - maturity) * market.penaltyRate());
            maxAssets -= actualRepay;
          }
        }
        fixedAssets += actualRepay;
      }
      if ((1 << i) > packedMaturities || maxAssets == 0) break;
    }
    (, , uint256 shares) = market.accounts(account);
    if (maxAssets > 0 && shares > 0) {
      uint256 borrowShares = market.previewRepay(maxAssets);
      if (borrowShares > 0) {
        borrowShares = Math.min(borrowShares, shares);
        floatingAssets += market.previewRefund(borrowShares);
      }
    }
    (lv.lendersAssets, lv.seizeAssets) = auditor.calculateSeize(
      market,
      collateralMarket,
      account,
      fixedAssets + floatingAssets
    );
    lv.repayAssets = fixedAssets + floatingAssets;
    lv.debtReduction += floatingAssets;
  }

  function previewBackupDebtReduction(
    Market market,
    address account,
    uint256 maturity,
    uint256 debtCovered
  ) internal view returns (uint256) {
    FixedLib.Position memory position;
    FixedLib.Pool memory pool;

    (pool.borrowed, pool.supplied, , ) = market.fixedPools(maturity);
    (position.principal, position.fee) = market.fixedBorrowPositions(maturity, account);
    uint256 principalCovered = debtCovered.mulDivDown(position.principal, position.principal + position.fee);
    pool.borrowed = pool.borrowed - principalCovered;
    return Math.min(pool.borrowed - Math.min(pool.borrowed, pool.supplied), principalCovered);
  }

  function rawCollateral(address account) internal view returns (uint256 sumCollateral) {
    uint256 marketMap = auditor.accountMarkets(account);
    for (uint256 i = 0; i < auditor.allMarkets().length; ++i) {
      Market market = auditor.marketList(i);
      if ((marketMap & (1 << i)) != 0) {
        (, uint8 decimals, , , IPriceFeed priceFeed) = auditor.markets(market);
        (uint256 balance, ) = market.accountSnapshot(account);
        sumCollateral += balance.mulDivDown(uint256(priceFeed.latestAnswer()), 10 ** decimals);
      }
      if ((1 << i) > marketMap) break;
    }
  }

  function seizeAvailable(address account, Market market) internal view returns (uint256) {
    uint256 collateral = market.convertToAssets(market.balanceOf(account));
    (, uint8 decimals, , , IPriceFeed priceFeed) = auditor.markets(market);
    return collateral.mulDivDown(uint256(priceFeed.latestAnswer()), 10 ** decimals);
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
      (, , uint256 index, , ) = auditor.markets(marketToSimulate);
      if ((marketMap & (1 << index)) == 0) marketMap = marketMap | (1 << index);
    }
    for (uint256 i = 0; i < auditor.allMarkets().length; ++i) {
      Market market = auditor.marketList(i);
      if ((marketMap & (1 << i)) != 0) {
        Auditor.MarketData memory md;
        (md.adjustFactor, md.decimals, , , md.priceFeed) = auditor.markets(market);
        (vars.balance, vars.borrowBalance) = market.accountSnapshot(account);
        vars.price = uint256(md.priceFeed.latestAnswer());
        sumCollateral += vars.balance.mulDivDown(vars.price, 10 ** md.decimals).mulWadDown(md.adjustFactor);
        sumDebtPlusEffects += (vars.borrowBalance + (market == marketToSimulate ? borrowAssets : 0))
          .mulDivUp(vars.price, 10 ** md.decimals)
          .divWadUp(md.adjustFactor);
        if (market == marketToSimulate && withdrawAssets != 0) {
          sumDebtPlusEffects += withdrawAssets.mulDivDown(vars.price, 10 ** md.decimals).mulWadDown(md.adjustFactor);
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
    (, , uint256 index, , ) = auditor.markets(marketToSimulate);
    if ((marketMap & (1 << index)) == 0) marketMap = marketMap | (1 << index);
    for (uint256 i = 0; i < auditor.allMarkets().length; ++i) {
      Market market = auditor.marketList(i);
      if ((marketMap & (1 << i)) != 0) {
        (uint128 adjustFactor, uint8 decimals, , , IPriceFeed priceFeed) = auditor.markets(market);
        if (market == marketToSimulate) {
          (vars.balance, vars.borrowBalance) = previewAccountSnapshot(market, account, borrowAssets, borrowShares);
        } else (vars.balance, vars.borrowBalance) = market.accountSnapshot(account);
        vars.price = uint256(priceFeed.latestAnswer());
        sumCollateral += vars.balance.mulDivDown(vars.price, 10 ** decimals).mulWadDown(adjustFactor);
        sumDebtPlusEffects += vars.borrowBalance.mulDivUp(vars.price, 10 ** decimals).divWadUp(adjustFactor);
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
    (, uint256 packedMaturities, ) = market.accounts(account);
    uint256 baseMaturity = packedMaturities % (1 << 32);
    packedMaturities = packedMaturities >> 32;
    for (uint256 i = 0; i < 224; ++i) {
      if ((packedMaturities & (1 << i)) != 0) {
        uint256 maturity = baseMaturity + (i * FixedLib.INTERVAL);
        (uint256 principal, uint256 fee) = market.fixedBorrowPositions(maturity, account);
        uint256 positionAssets = principal + fee;

        debt += positionAssets;

        if (block.timestamp > maturity) {
          debt += positionAssets.mulWadDown((block.timestamp - maturity) * memPenaltyRate);
        }
      }
      if ((1 << i) > packedMaturities) break;
    }
    (, , uint256 shares) = market.accounts(account);
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
    uint256 floatingUtilization = memFloatingAssets > 0
      ? Math.min(memFloatingDebt.divWadUp(memFloatingAssets), 1e18)
      : 0;
    uint256 newDebt = memFloatingDebt.mulWadDown(
      market.interestRateModel().floatingRate(floatingUtilization).mulDivDown(
        block.timestamp - market.lastFloatingDebtUpdate(),
        365 days
      )
    );
    return memFloatingDebt + newDebt;
  }

  function previewDepositYield(Market market, uint256 maturity, uint256 amount) internal view returns (uint256 yield) {
    (uint256 borrowed, uint256 supplied, uint256 unassignedEarnings, uint256 lastAccrual) = market.fixedPools(maturity);
    uint256 memBackupSupplied = borrowed - Math.min(borrowed, supplied);
    if (memBackupSupplied != 0) {
      unassignedEarnings -= unassignedEarnings.mulDivDown(block.timestamp - lastAccrual, maturity - lastAccrual);
      yield = unassignedEarnings.mulDivDown(Math.min(amount, memBackupSupplied), memBackupSupplied);
      uint256 backupFee = yield.mulWadDown(market.backupFeeRate());
      yield -= backupFee;
    }
  }

  function previewNewFloatingDebt(Market market) internal view returns (uint256) {
    InterestRateModel memIRM = market.interestRateModel();
    uint256 memFloatingDebt = market.floatingDebt();
    uint256 memFloatingAssets = market.floatingAssets();
    uint256 floatingUtilization = memFloatingAssets > 0
      ? Math.min(memFloatingDebt.divWadUp(memFloatingAssets), 1e18)
      : 0;
    return
      memFloatingDebt.mulWadDown(
        memIRM.floatingRate(floatingUtilization).mulDivDown(block.timestamp - market.lastFloatingDebtUpdate(), 365 days)
      );
  }

  function previewAccumulatedEarnings(Market market) internal view returns (uint256) {
    uint256 elapsed = block.timestamp - market.lastAccumulatorAccrual();
    if (elapsed == 0) return 0;
    return
      elapsed.mulDivDown(
        market.earningsAccumulator() + newAccumulatedEarnings[market],
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

  struct BadDebtVars {
    uint256 balance;
    uint256 repayMarketDebt;
    uint256 collateralMarketDebt;
    uint256 adjustedCollateral;
  }

  struct LiquidationVars {
    uint256 repayAssets;
    uint256 seizeAssets;
    uint256 lendersAssets;
    uint256 debtReduction;
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
