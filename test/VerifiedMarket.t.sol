// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

import { MarketTest } from "./Market.t.sol";
import { Auditor } from "../contracts/Auditor.sol";
import { InterestRateModel } from "../contracts/InterestRateModel.sol";
import { Market, ZeroRepay } from "../contracts/Market.sol";
import { MockBorrowRate } from "../contracts/mocks/MockBorrowRate.sol";
import { Firewall } from "../contracts/verified/Firewall.sol";
import { NotAllowed, RemainingDebt, VerifiedAuditor } from "../contracts/verified/VerifiedAuditor.sol";
import { Locked, NotAuditor, Unlocked, VerifiedMarket } from "../contracts/verified/VerifiedMarket.sol";

import { MockInterestRateModel } from "../contracts/mocks/MockInterestRateModel.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import { FixedLib } from "../contracts/utils/FixedLib.sol";

contract VerifiedMarketTest is MarketTest {
  using FixedPointMathLib for uint256;

  uint256 public immutable lendersIncentive = 0.01e18;
  uint256 public immutable liquidatorIncentive = 0.09e18;

  Firewall public firewall;
  MockPriceFeed public marketWETHPriceFeed;

  function setUp() external override {
    vm.warp(0);
    irm = new MockInterestRateModel(0.1e18);
    asset = new MockERC20("DAI", "DAI", 18);
    weth = new MockERC20("WETH", "WETH", 18);

    firewall = Firewall(address(new ERC1967Proxy(address(new Firewall()), "")));
    firewall.initialize();
    firewall.grantRole(firewall.ALLOWER_ROLE(), address(this));
    firewall.allow(address(this), true);
    vm.label(address(firewall), "Firewall");

    auditor = VerifiedAuditor(address(new ERC1967Proxy(address(new VerifiedAuditor(18)), "")));
    VerifiedAuditor(address(auditor)).initializeVerified(
      Auditor.LiquidationIncentive(uint128(liquidatorIncentive), uint128(lendersIncentive)),
      firewall
    );
    vm.label(address(auditor), "Auditor");

    marketWETH = VerifiedMarket(
      address(new ERC1967Proxy(address(new VerifiedMarket(weth, VerifiedAuditor(address(auditor)))), ""))
    );
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
    vm.label(address(marketWETH), "MarketWETH");

    market = VerifiedMarket(
      address(new ERC1967Proxy(address(new VerifiedMarket(asset, VerifiedAuditor(address(auditor)))), ""))
    );
    market.initialize(
      "DAI",
      3,
      type(uint256).max,
      1e18,
      InterestRateModel(address(irm)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    vm.label(address(market), "MarketDAI");

    marketWETHPriceFeed = MockPriceFeed(address(auditor.BASE_FEED()));
    daiPriceFeed = new MockPriceFeed(18, 1e18);

    auditor.enableMarket(market, daiPriceFeed, 0.8e18, false);
    auditor.enableMarket(marketWETH, marketWETHPriceFeed, 0.9e18, false);
    auditor.enterMarket(marketWETH);

    weth.mint(address(this), 1_000_000 ether);
    weth.approve(address(marketWETH), type(uint256).max);
    asset.mint(address(this), 1_000_000 ether);
    asset.approve(address(market), type(uint256).max);

    firewall.allow(BOB, true);
    firewall.allow(ALICE, true);
    firewall.allow(account, true);
    firewall.allow(liquidator, true);
    firewall.allow(attacker, true);

    vm.startPrank(BOB);
    asset.mint(BOB, 50_000 ether);
    asset.approve(address(market), type(uint256).max);
    weth.approve(address(marketWETH), type(uint256).max);

    vm.startPrank(ALICE);
    asset.mint(ALICE, 50_000 ether);
    asset.approve(address(market), type(uint256).max);
    weth.mint(ALICE, 1000 ether);
    weth.approve(address(marketWETH), type(uint256).max);
    vm.stopPrank();
  }

  function test_borrow_borrows_whenBorrowerIsAllowed() external {
    marketWETH.deposit(100 ether, address(this));

    marketWETH.borrow(10 ether, BOB, address(this));

    assertEq(weth.balanceOf(BOB), 10 ether);
  }

  function test_borrow_reverts_withNotAllowed_whenBorrowerIsNotAllowed() external {
    marketWETH.deposit(100 ether, BOB);

    firewall.allow(BOB, false);
    vm.startPrank(BOB);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.borrow(10 ether, address(this), BOB);
  }

  function test_borrowAtMaturity_borrows_whenBorrowerIsAllowed() external {
    marketWETH.deposit(100 ether, address(this));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, 11 ether, BOB, address(this));
    assertEq(weth.balanceOf(BOB), 10 ether);
  }

  function test_borrowAtMaturity_reverts_withNotAllowed_whenBorrowerIsNotAllowed() external {
    marketWETH.deposit(100 ether, BOB);
    firewall.allow(BOB, false);

    vm.startPrank(BOB);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, 11 ether, BOB, BOB);
  }

  function test_deposit_deposits_whenSenderAndReceiverAreAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    assertEq(marketWETH.maxWithdraw(address(this)), 10 ether);

    marketWETH.deposit(10 ether, BOB);
    assertEq(marketWETH.maxWithdraw(BOB), 10 ether);
  }

  function test_mint_mints_whenSenderAndReceiverAreAllowed() external {
    marketWETH.mint(10 ether, address(this));
    assertEq(marketWETH.balanceOf(address(this)), 10 ether);

    marketWETH.mint(10 ether, BOB);
    assertEq(marketWETH.balanceOf(BOB), 10 ether);
  }

  function test_deposit_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    weth.mint(BOB, 10 ether);
    firewall.allow(BOB, false);

    vm.startPrank(BOB);
    weth.approve(address(marketWETH), 10 ether);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.deposit(10 ether, address(this));
  }

  function test_deposit_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    firewall.allow(BOB, false);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.deposit(10 ether, BOB);
  }

  function test_deposit_revert_withNotAllowed_whenBothSenderAndReceiverAreNotAllowed() external {
    weth.mint(BOB, 10 ether);
    firewall.allow(BOB, false);

    vm.startPrank(BOB);
    weth.approve(address(marketWETH), 10 ether);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.deposit(10 ether, BOB);
  }

  function test_mint_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    weth.mint(BOB, 10 ether);

    firewall.allow(BOB, false);
    vm.startPrank(BOB);
    weth.approve(address(marketWETH), 10 ether);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.mint(10 ether, address(this));
  }

  function test_mint_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    firewall.allow(BOB, false);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.mint(10 ether, BOB);
  }

  function test_mint_revert_withNotAllowed_whenBothSenderAndReceiverAreNotAllowed() external {
    weth.mint(BOB, 10 ether);

    firewall.allow(BOB, false);
    vm.startPrank(BOB);
    weth.approve(address(marketWETH), 10 ether);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.mint(10 ether, BOB);
  }

  function test_depositAtMaturity_deposits_whenSenderAndReceiverAreAllowed() external {
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, address(this));

    (uint256 principal, ) = marketWETH.fixedDepositPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal, 10 ether);

    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, BOB);
    (principal, ) = marketWETH.fixedDepositPositions(FixedLib.INTERVAL, BOB);
    assertEq(principal, 10 ether);
  }

  function test_depositAtMaturity_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    firewall.allow(BOB, false);
    vm.startPrank(BOB);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, address(this));
  }

  function test_depositAtMaturity_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    firewall.allow(BOB, false);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, BOB);
  }

  function test_redeem_redeems_whenSenderIsAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    uint256 assets = marketWETH.redeem(10 ether, BOB, address(this));
    assertEq(weth.balanceOf(BOB), assets);
  }

  function test_redeem_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    marketWETH.deposit(10 ether, BOB);
    firewall.allow(BOB, false);

    vm.startPrank(BOB);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.redeem(10 ether, address(this), BOB);
  }

  function test_transfer_transfers_whenSenderAndReceiverAreAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    marketWETH.transfer(BOB, 10 ether);
    assertEq(marketWETH.maxWithdraw(BOB), 10 ether);
  }

  function test_transfer_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    firewall.allow(BOB, false);

    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.transfer(BOB, 10 ether);
  }

  function test_transfer_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    marketWETH.deposit(10 ether, BOB);
    firewall.allow(BOB, false);

    vm.startPrank(BOB);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.transfer(address(this), 10 ether);
  }

  function test_transfer_reverts_withNotAllowed_whenBothSenderAndReceiverAreNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    firewall.allow(BOB, false);
    firewall.allow(address(this), false);

    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.transfer(BOB, 10 ether);
  }

  function test_transferFrom_transfers_whenSenderAndReceiverAreAllowed() external {
    marketWETH.deposit(10 ether, address(this));

    marketWETH.approve(BOB, 10 ether);
    vm.startPrank(BOB);
    marketWETH.transferFrom(address(this), BOB, 10 ether);
    assertEq(marketWETH.maxWithdraw(BOB), 10 ether);
  }

  function test_transferFrom_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    firewall.allow(BOB, false);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.transferFrom(address(this), BOB, 10 ether);
  }

  function test_transferFrom_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    marketWETH.deposit(10 ether, BOB);
    firewall.allow(BOB, false);

    vm.startPrank(BOB);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.transferFrom(BOB, address(this), 10 ether);
  }

  function test_transferFrom_reverts_withNotAllowed_whenBothSenderAndReceiverAreNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    firewall.allow(address(this), false);
    firewall.allow(BOB, false);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.transferFrom(address(this), BOB, 10 ether);
  }

  function test_withdraw_withdraws_whenSenderIsAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    uint256 balance = weth.balanceOf(BOB);
    marketWETH.withdraw(10 ether, BOB, address(this));
    assertEq(weth.balanceOf(BOB), balance + 10 ether);
  }

  function test_withdraw_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    marketWETH.deposit(10 ether, BOB);
    firewall.allow(BOB, false);

    vm.startPrank(BOB);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.withdraw(10 ether, address(this), BOB);
  }

  function test_withdrawAtMaturity_withdraws_whenOwnerIsAllowed() external {
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, BOB);

    skip(FixedLib.INTERVAL);
    vm.startPrank(BOB);
    marketWETH.withdrawAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, BOB, BOB);

    (uint256 principal, ) = marketWETH.fixedDepositPositions(FixedLib.INTERVAL, BOB);
    assertEq(principal, 0);
    assertEq(weth.balanceOf(BOB), 10 ether);
  }

  function test_withdrawAtMaturity_reverts_withNotAllowed_whenOwnerIsNotAllowed() external {
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, BOB);

    skip(FixedLib.INTERVAL);
    firewall.allow(BOB, false);
    vm.startPrank(BOB);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.withdrawAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, BOB, BOB);

    (uint256 principal, ) = marketWETH.fixedDepositPositions(FixedLib.INTERVAL, BOB);
    assertEq(principal, 10 ether);
    assertEq(weth.balanceOf(BOB), 0);
  }

  function test_liquidateAllowedAccount_liquidates_withIncentives() external {
    marketWETH.deposit(10 ether, address(this));

    market.deposit(5_000e18, BOB);

    vm.startPrank(BOB);
    auditor.enterMarket(market);
    marketWETH.borrow(1 ether, BOB, BOB);
    vm.stopPrank();

    uint256 usdcBefore = asset.balanceOf(address(this));
    assertEq(marketWETH.earningsAccumulator(), 0);

    marketWETHPriceFeed = new MockPriceFeed(18, 4_000e18);
    auditor.setPriceFeed(marketWETH, marketWETHPriceFeed);
    uint256 repaidAssets = marketWETH.liquidate(BOB, 1 ether, market);
    assertEq(
      marketWETH.earningsAccumulator(),
      repaidAssets.mulWad(lendersIncentive),
      "10% incentive to lenders != expected"
    );
    assertEq(
      asset.balanceOf(address(this)) - usdcBefore + market.maxWithdraw(BOB),
      5_000e18,
      "asset didn't go to liquidator"
    );
  }

  function test_liquidateNotAllowedAccount_liquidates_withoutIncentives() external {
    marketWETH.deposit(10 ether, address(this));

    market.deposit(5_000e18, BOB);

    vm.startPrank(BOB);
    auditor.enterMarket(market);
    marketWETH.borrow(1 ether, BOB, BOB);
    vm.stopPrank();

    firewall.allow(BOB, false);

    marketWETHPriceFeed = new MockPriceFeed(18, 3_500e18);
    auditor.setPriceFeed(marketWETH, marketWETHPriceFeed);

    uint256 repaidAssets = marketWETH.liquidate(BOB, 1 ether, market);
    assertEq(marketWETH.earningsAccumulator(), 0, "lenders got incentives");
    assertEq(repaidAssets, 1 ether, "deb't didn't repay in full");
    assertEq(marketWETH.previewDebt(BOB), 0, "position not closed");
    assertEq(market.maxWithdraw(BOB), 5_000e18 - 3_500e18, "collateral left"); // eth price is 3_500e18
  }

  function test_liquidateNotAllowedAccount_underwater_liquidates_withoutIncentives() external {
    marketWETH.deposit(10 ether, address(this));

    market.deposit(5_000e18, BOB);

    vm.startPrank(BOB);
    auditor.enterMarket(market);
    marketWETH.borrow(1 ether, BOB, BOB);
    vm.stopPrank();

    firewall.allow(BOB, false);

    marketWETHPriceFeed = new MockPriceFeed(18, 4_000e18);
    auditor.setPriceFeed(marketWETH, marketWETHPriceFeed);
    uint256 repaidAssets = marketWETH.liquidate(BOB, 1 ether, market);

    assertEq(marketWETH.earningsAccumulator(), 0, "lenders got incentives");
    assertEq(repaidAssets, 1 ether, "deb't didn't repay in full");
    assertEq(marketWETH.previewDebt(BOB), 0, "position not closed");
    assertEq(market.maxWithdraw(BOB), 5_000e18 - 4_000e18, "collateral left");
  }

  function test_liquidate_reverts_withNotAllowed_whenLiquidatorIsNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));

    market.deposit(5_000e18, BOB);

    vm.startPrank(BOB);
    auditor.enterMarket(market);
    marketWETH.borrow(1 ether, BOB, BOB);
    vm.stopPrank();

    marketWETHPriceFeed = new MockPriceFeed(18, 6_000e18);
    auditor.setPriceFeed(marketWETH, marketWETHPriceFeed);

    firewall.allow(address(this), false);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, address(this)));
    marketWETH.liquidate(BOB, 1 ether, market);
  }

  function test_lock_reverts_withRemainingDebt_whenAccountHasDebt() external {
    marketWETH.deposit(10 ether, BOB);

    vm.prank(BOB);
    marketWETH.borrow(1 ether, BOB, BOB);

    firewall.allow(BOB, false);

    vm.expectRevert(abi.encodeWithSelector(RemainingDebt.selector));
    VerifiedAuditor(address(auditor)).lock(BOB);
  }

  function test_lock_locks_whenAccountHasNoDebt() external {
    marketWETH.deposit(10 ether, BOB);
    firewall.allow(BOB, false);

    assertEq(marketWETH.balanceOf(BOB), 10 ether, "BOB has wrong shares");
    assertEq(marketWETH.totalAssets(), 10 ether, "wrong total assets");

    VerifiedAuditor(address(auditor)).lock(BOB);

    assertEq(marketWETH.balanceOf(BOB), 0, "BOB preserved shares");
    assertEq(marketWETH.totalAssets(), 0, "total assets preserved");
  }

  function test_lock_locks_whenAccountHasFixedDeposits() external {
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, BOB);

    firewall.allow(BOB, false);
    VerifiedAuditor(address(auditor)).lock(BOB);

    assertGt(VerifiedMarket(address(marketWETH)).lockedAssets(BOB), 0, "locked assets not accounted for BOB");
    (uint256 deposits, ) = marketWETH.fixedConsolidated(BOB);
    assertEq(deposits, 0, "fixed deposits not accounted for BOB");
    (uint256 totalDeposits, ) = marketWETH.fixedOps();
    assertEq(totalDeposits, 0, "fixed deposits not accounted for ops");
    (uint256 fixedDeposits, , ) = marketWETH.accounts(BOB);
    assertEq(fixedDeposits, 0, "fixed deposits not accounted for account");
  }

  function test_lock_emits_locked() external {
    marketWETH.deposit(10 ether, BOB);
    firewall.allow(BOB, false);

    vm.expectEmit(true, true, true, true);
    emit Locked(BOB, 10 ether);
    VerifiedAuditor(address(auditor)).lock(BOB);
  }

  function test_lock_emits_seize() external {
    marketWETH.deposit(10 ether, BOB);
    firewall.allow(BOB, false);

    vm.expectEmit(true, true, true, true);
    emit Market.Seize(address(auditor), BOB, 10 ether);
    VerifiedAuditor(address(auditor)).lock(BOB);
  }

  function test_lock_reverts_withNotAuditor_whenNotCalledByAuditor() external {
    vm.expectRevert(abi.encodeWithSelector(NotAuditor.selector));
    VerifiedMarket(address(marketWETH)).lock(BOB);
  }

  function test_repay_repays_whenBorrowerAndRepayerAreAllowed() external {
    marketWETH.deposit(10 ether, BOB);
    vm.prank(BOB);
    marketWETH.borrow(1 ether, BOB, BOB);

    marketWETH.repay(1 ether, BOB);

    assertEq(marketWETH.previewDebt(BOB), 0);
    assertEq(weth.balanceOf(BOB), 1 ether);
  }

  function test_repay_reverts_withNotAllowed_whenBorrowerIsNotAllowed() external {
    marketWETH.deposit(10 ether, BOB);

    vm.prank(BOB);
    marketWETH.borrow(1 ether, BOB, BOB);

    firewall.allow(BOB, false);

    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.repay(1 ether, BOB);
  }

  function test_repay_reverts_withNotAllowed_whenRepayerIsNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));

    firewall.allow(BOB, false);

    vm.startPrank(BOB);
    weth.mint(BOB, 1 ether);
    weth.approve(address(marketWETH), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.repay(1 ether, address(this));
  }

  function test_repay_reverts_withNotAllowed_whenBothBorrowerAndRepayerAreNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));

    firewall.allow(address(this), false);
    firewall.allow(BOB, false);

    vm.startPrank(BOB);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.repay(1 ether, address(this));
  }

  function test_repayAtMaturity_repays_whenBorrowerAndRepayerAreAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    uint256 assetsOwed = marketWETH.borrowAtMaturity(
      FixedLib.INTERVAL,
      1 ether,
      type(uint256).max,
      address(this),
      address(this)
    );

    weth.mint(BOB, 10 ether);
    vm.startPrank(BOB);
    weth.approve(address(marketWETH), type(uint256).max);
    assertEq(marketWETH.previewDebt(address(this)), assetsOwed);
    marketWETH.repayAtMaturity(FixedLib.INTERVAL, assetsOwed, type(uint256).max, address(this));

    assertEq(marketWETH.previewDebt(address(this)), 0);
  }

  function test_repayAtMaturity_reverts_withNotAllowed_whenBorrowerIsNotAllowed() external {
    marketWETH.deposit(10 ether, BOB);
    vm.prank(BOB);
    uint256 assetsOwed = marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, type(uint256).max, BOB, BOB);

    firewall.allow(BOB, false);

    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.repayAtMaturity(FixedLib.INTERVAL, assetsOwed, type(uint256).max, BOB);
  }

  function test_repayAtMaturity_reverts_withNotAllowed_whenRepayerIsNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    uint256 assetsOwed = marketWETH.borrowAtMaturity(
      FixedLib.INTERVAL,
      1 ether,
      type(uint256).max,
      address(this),
      address(this)
    );

    firewall.allow(BOB, false);

    weth.mint(BOB, 10 ether);
    vm.startPrank(BOB);
    weth.approve(address(marketWETH), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.repayAtMaturity(FixedLib.INTERVAL, assetsOwed, type(uint256).max, address(this));
  }

  function test_repayAtMaturity_reverts_withNotAllowed_whenBothBorrowerAndRepayerAreNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    uint256 assetsOwed = marketWETH.borrowAtMaturity(
      FixedLib.INTERVAL,
      1 ether,
      type(uint256).max,
      address(this),
      address(this)
    );

    firewall.allow(address(this), false);
    firewall.allow(BOB, false);
    weth.mint(BOB, 10 ether);

    vm.startPrank(BOB);
    weth.approve(address(marketWETH), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.repayAtMaturity(FixedLib.INTERVAL, assetsOwed, type(uint256).max, address(this));
  }

  function test_refund_refunds_whenBorrowerAndRefunderAreAllowed() external {
    marketWETH.deposit(10 ether, BOB);

    vm.prank(BOB);
    uint256 borrowShares = marketWETH.borrow(1 ether, BOB, BOB);

    assertEq(marketWETH.previewDebt(BOB), 1 ether);

    marketWETH.refund(borrowShares, BOB);

    assertEq(marketWETH.previewDebt(BOB), 0);
  }

  function test_refund_reverts_withNotAllowed_whenBorrowerIsNotAllowed() external {
    marketWETH.deposit(10 ether, BOB);

    vm.prank(BOB);
    uint256 borrowShares = marketWETH.borrow(1 ether, BOB, BOB);

    firewall.allow(BOB, false);

    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.refund(borrowShares, BOB);
  }

  function test_refund_reverts_withNotAllowed_whenRefunderIsNotAllowed() external {
    marketWETH.deposit(10 ether, BOB);
    vm.prank(BOB);
    uint256 borrowShares = marketWETH.borrow(1 ether, BOB, BOB);

    firewall.allow(address(this), false);

    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, address(this)));
    marketWETH.refund(borrowShares, BOB);
  }

  function test_refund_reverts_withNotAllowed_whenBothBorrowerAndRefunderAreNotAllowed() external {
    marketWETH.deposit(10 ether, BOB);
    vm.prank(BOB);
    uint256 borrowShares = marketWETH.borrow(1 ether, BOB, BOB);

    firewall.allow(address(this), false);
    firewall.allow(BOB, false);

    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, address(this)));
    marketWETH.refund(borrowShares, BOB);
  }

  function test_unlock_unlocks_whenAccountIsAllowedBack() external {
    marketWETH.deposit(10 ether, BOB);
    firewall.allow(BOB, false);

    assertEq(marketWETH.balanceOf(BOB), 10 ether, "BOB has wrong shares");
    assertEq(marketWETH.totalAssets(), 10 ether, "wrong total assets");

    VerifiedAuditor(address(auditor)).lock(BOB);

    firewall.allow(BOB, true);

    assertEq(marketWETH.balanceOf(BOB), 0, "BOB preserved shares");
    assertEq(marketWETH.totalAssets(), 0, "total assets preserved");

    VerifiedAuditor(address(auditor)).unlock(BOB);

    assertEq(marketWETH.balanceOf(BOB), 10 ether, "BOB has wrong shares");
    assertEq(marketWETH.totalAssets(), 10 ether, "wrong total assets");
  }

  function test_unlock_reverts_withNotAuditor_whenNotCalledByAuditor() external {
    vm.expectRevert(abi.encodeWithSelector(NotAuditor.selector));
    VerifiedMarket(address(marketWETH)).unlock(BOB);
  }

  function test_unlock_updatesFloatingAssets() external {
    marketWETH.deposit(10 ether, BOB);

    firewall.allow(BOB, false);
    VerifiedAuditor(address(auditor)).lock(BOB);

    assertEq(marketWETH.floatingAssets(), 0, "floating assets not updated");

    firewall.allow(BOB, true);
    VerifiedAuditor(address(auditor)).unlock(BOB);

    assertEq(marketWETH.floatingAssets(), 10 ether, "floating assets not updated");
  }

  function test_unlock_emits_unlocked() external {
    marketWETH.deposit(10 ether, BOB);
    firewall.allow(BOB, false);
    VerifiedAuditor(address(auditor)).lock(BOB);

    firewall.allow(BOB, true);

    vm.expectEmit(true, true, true, true);
    emit Unlocked(BOB, 10 ether);
    VerifiedAuditor(address(auditor)).unlock(BOB);
  }

  function seedAccumulator(Market market_, uint256 assets) internal {
    market_.setBackupFeeRate(1e18);
    market_.setInterestRateModel(InterestRateModel(address(new MockBorrowRate(1e18))));
    market_.borrowAtMaturity(FixedLib.INTERVAL, assets, type(uint256).max, address(this), address(this));
    market_.depositAtMaturity(FixedLib.INTERVAL, assets, 0, address(this));
    market_.repayAtMaturity(FixedLib.INTERVAL, type(uint256).max, type(uint256).max, address(this));
  }

  function test_unwind_liquidatesAndLocks_whenDisallowedIsHealthyWithCollateralOnly() external {
    marketWETHPriceFeed = new MockPriceFeed(18, 1_000e18);
    auditor.setPriceFeed(marketWETH, marketWETHPriceFeed);
    marketWETH.deposit(10 ether, address(this));

    market.deposit(5_000e18, BOB);
    vm.startPrank(BOB);
    auditor.enterMarket(market);
    marketWETH.borrow(1 ether, BOB, BOB);
    vm.stopPrank();

    firewall.allow(BOB, false);

    // position is healthy, yet the disallowed branch lets it be fully repaid by liquidation
    (uint256 collateral, uint256 debt) = auditor.accountLiquidity(BOB, Market(address(0)), 0);
    assertGt(collateral, debt, "position should be healthy");

    uint256 repaid = marketWETH.liquidate(BOB, type(uint256).max, market);
    assertEq(repaid, 1 ether, "debt not fully repaid");
    assertEq(marketWETH.previewDebt(BOB), 0, "debt left");
    assertEq(marketWETH.earningsAccumulator(), 0, "incentives were charged");

    VerifiedAuditor(address(auditor)).lock(BOB);
    assertEq(market.balanceOf(BOB), 0, "shares left");
    assertEq(VerifiedMarket(address(market)).lockedAssets(BOB), 4_000e18, "wrong locked assets");
  }

  function test_unwind_liquidatesClearsBadDebtAndLocks_whenDisallowedIsUnderwaterWithCollateralOnly() external {
    marketWETHPriceFeed = new MockPriceFeed(18, 1_000e18);
    auditor.setPriceFeed(marketWETH, marketWETHPriceFeed);
    marketWETH.deposit(10 ether, address(this));

    market.deposit(5_000e18, BOB);
    vm.startPrank(BOB);
    auditor.enterMarket(market);
    marketWETH.borrow(1 ether, BOB, BOB);
    vm.stopPrank();

    // bad debt can only be cleared against the accumulator, so it must have funds
    seedAccumulator(marketWETH, 1 ether);
    assertGe(marketWETH.earningsAccumulator(), 0.2 ether, "accumulator not seeded");

    marketWETHPriceFeed = new MockPriceFeed(18, 6_000e18);
    auditor.setPriceFeed(marketWETH, marketWETHPriceFeed);
    (uint256 collateral, uint256 debt) = auditor.accountLiquidity(BOB, Market(address(0)), 0);
    assertLt(collateral, debt, "position should be underwater");

    firewall.allow(BOB, false);

    // seizes all collateral and clears the remainder as bad debt within the same call
    marketWETH.liquidate(BOB, type(uint256).max, market);
    assertEq(market.balanceOf(BOB), 0, "collateral left");
    assertEq(marketWETH.previewDebt(BOB), 0, "debt left");

    VerifiedAuditor(address(auditor)).lock(BOB);
    assertEq(VerifiedMarket(address(market)).lockedAssets(BOB), 0, "nothing should be left to lock");
    assertEq(VerifiedMarket(address(marketWETH)).lockedAssets(BOB), 0, "nothing should be left to lock");
  }

  function test_unwind_liquidatesAndLocks_whenDisallowedIsHealthyWithMixedSupply() external {
    auditor.setNonCollateral(market, true);

    vm.prank(BOB);
    auditor.enterMarket(marketWETH);
    marketWETH.deposit(10 ether, BOB);
    market.deposit(1_000e18, BOB);
    vm.prank(BOB);
    marketWETH.borrow(1 ether, BOB, BOB);

    firewall.allow(BOB, false);

    // seizing from the enabled collateral market still works and repays the whole debt
    uint256 repaid = marketWETH.liquidate(BOB, type(uint256).max, marketWETH);
    assertEq(repaid, 1 ether, "debt not fully repaid");
    assertEq(marketWETH.previewDebt(BOB), 0, "debt left");

    // lock seizes the remaining collateral and the non-collateral supply
    VerifiedAuditor(address(auditor)).lock(BOB);
    assertEq(marketWETH.balanceOf(BOB), 0, "collateral shares left");
    assertEq(market.balanceOf(BOB), 0, "non-collateral shares left");
    assertEq(VerifiedMarket(address(marketWETH)).lockedAssets(BOB), 9 ether, "wrong locked collateral");
    assertEq(VerifiedMarket(address(market)).lockedAssets(BOB), 1_000e18, "wrong locked non-collateral supply");
  }

  function test_unwind_liquidatesClearsBadDebtAndLocks_whenDisallowedIsUnderwaterWithMixedSupply() external {
    marketWETHPriceFeed = new MockPriceFeed(18, 1_000e18);
    auditor.setPriceFeed(marketWETH, marketWETHPriceFeed);
    auditor.setNonCollateral(market, true);

    marketWETH.deposit(1 ether, address(this));
    marketWETH.deposit(1 ether, BOB);
    market.deposit(1_000e18, BOB);
    vm.startPrank(BOB);
    auditor.enterMarket(marketWETH);
    market.borrow(500e18, BOB, BOB);
    vm.stopPrank();

    seedAccumulator(market, 200e18);
    assertGe(market.earningsAccumulator(), 150e18, "accumulator not seeded");

    marketWETHPriceFeed = new MockPriceFeed(18, 400e18);
    auditor.setPriceFeed(marketWETH, marketWETHPriceFeed);
    (uint256 collateral, uint256 debt) = auditor.accountLiquidity(BOB, Market(address(0)), 0);
    assertLt(collateral, debt, "position should be underwater");

    firewall.allow(BOB, false);

    // seizes all weth collateral and clears the remainder as bad debt, non-collateral supply stays untouched
    uint256 repaid = market.liquidate(BOB, type(uint256).max, marketWETH);
    assertEq(repaid, 400e18, "wrong repaid amount");
    assertEq(marketWETH.balanceOf(BOB), 0, "collateral left");
    assertEq(market.previewDebt(BOB), 0, "debt left");
    assertEq(market.balanceOf(BOB), 1_000e18, "non-collateral supply was consumed");

    VerifiedAuditor(address(auditor)).lock(BOB);
    assertEq(market.balanceOf(BOB), 0, "non-collateral shares left");
    assertEq(VerifiedMarket(address(market)).lockedAssets(BOB), 1_000e18, "wrong locked non-collateral supply");
  }

  function test_unwind_locks_whenDisallowedHasOnlyNonCollateralSupplyAndNoDebt() external {
    auditor.setNonCollateral(market, true);
    market.deposit(500e18, BOB);
    market.depositAtMaturity(FixedLib.INTERVAL, 100e18, 0, BOB);

    firewall.allow(BOB, false);
    VerifiedAuditor(address(auditor)).lock(BOB);

    assertEq(market.balanceOf(BOB), 0, "shares left");
    (uint256 principal, ) = market.fixedDepositPositions(FixedLib.INTERVAL, BOB);
    assertEq(principal, 0, "fixed deposit left");
    assertGt(VerifiedMarket(address(market)).lockedAssets(BOB), 500e18, "wrong locked assets");
  }

  function test_unwind_isStranded_whenDisallowedHasDebtAndOnlyNonCollateralSupply() external {
    marketWETH.deposit(10 ether, address(this));

    market.deposit(1_000e18, BOB);
    vm.startPrank(BOB);
    auditor.enterMarket(market);
    marketWETH.borrow(1 ether, BOB, BOB);
    vm.stopPrank();

    auditor.setNonCollateral(market, true);
    firewall.allow(BOB, false);

    // liquidation cannot seize the non-collateral supply: seizeAvailable == 0 -> maxRepayAssets == 0
    vm.expectRevert(ZeroRepay.selector);
    marketWETH.liquidate(BOB, type(uint256).max, market);

    // nor seize from a market where the account holds nothing
    vm.expectRevert(ZeroRepay.selector);
    marketWETH.liquidate(BOB, type(uint256).max, marketWETH);

    // debt cannot be repaid on behalf of a disallowed borrower
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, BOB));
    marketWETH.repay(1 ether, BOB);

    // bad debt cannot be cleared while the accumulator is empty
    auditor.handleBadDebt(BOB);
    assertEq(marketWETH.previewDebt(BOB), 1 ether, "debt should remain");

    // so the account cannot be locked either
    vm.expectRevert(RemainingDebt.selector);
    VerifiedAuditor(address(auditor)).lock(BOB);
  }

  function test_unwind_socializesDebt_whenDisallowedHasDebtAndOnlyNonCollateralSupply() external {
    marketWETH.deposit(10 ether, address(this));

    market.deposit(1_000e18, BOB);
    vm.startPrank(BOB);
    auditor.enterMarket(market);
    marketWETH.borrow(1 ether, BOB, BOB);
    vm.stopPrank();

    auditor.setNonCollateral(market, true);
    firewall.allow(BOB, false);

    seedAccumulator(marketWETH, 2 ether);
    uint256 accumulatorBefore = marketWETH.earningsAccumulator();
    assertGe(accumulatorBefore, 1 ether, "accumulator can't cover the debt");

    // the only way out: socialize the full debt to weth lenders even though BOB holds 1_000 dai
    auditor.handleBadDebt(BOB);
    assertEq(marketWETH.previewDebt(BOB), 0, "debt left");
    assertEq(accumulatorBefore - marketWETH.earningsAccumulator(), 1 ether, "lenders didn't absorb the debt");
    assertEq(market.maxWithdraw(BOB), 1_000e18, "non-collateral supply was consumed");

    VerifiedAuditor(address(auditor)).lock(BOB);
    assertEq(VerifiedMarket(address(market)).lockedAssets(BOB), 1_000e18, "supply not locked");
  }

  function test_unlock_afterOperating_unlocks() external {
    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));

    firewall.allow(address(this), false);

    vm.startPrank(BOB);
    weth.mint(BOB, 10 ether);
    weth.approve(address(marketWETH), type(uint256).max);
    marketWETH.liquidate(address(this), type(uint256).max, marketWETH);

    VerifiedAuditor(address(auditor)).lock(address(this));
    vm.stopPrank();

    assertEq(marketWETH.balanceOf(address(this)), 0);
    assertEq(marketWETH.previewDebt(address(this)), 0);
    assertEq(marketWETH.floatingAssets(), 0);
    assertEq(VerifiedMarket(address(marketWETH)).lockedAssets(address(this)), 9 ether);
    assertEq(marketWETH.totalAssets(), 0);
    assertEq(marketWETH.totalSupply(), 0);
    assertEq(marketWETH.floatingDebt(), 0);

    firewall.allow(address(this), true);

    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));

    assertEq(marketWETH.balanceOf(address(this)), 10 ether);
    assertEq(marketWETH.previewDebt(address(this)), 1 ether);
    assertEq(marketWETH.floatingAssets(), 10 ether);
    assertEq(VerifiedMarket(address(marketWETH)).lockedAssets(address(this)), 9 ether);
    assertEq(marketWETH.totalAssets(), 10 ether);

    VerifiedAuditor(address(auditor)).unlock(address(this));

    assertEq(marketWETH.balanceOf(address(this)), 19 ether);
    assertEq(marketWETH.previewDebt(address(this)), 1 ether);
    assertEq(marketWETH.floatingAssets(), 19 ether);
    assertEq(VerifiedMarket(address(marketWETH)).lockedAssets(address(this)), 0);
    assertEq(marketWETH.totalAssets(), 19 ether);
    assertEq(marketWETH.totalSupply(), 19 ether);
    assertEq(marketWETH.floatingDebt(), 1 ether);
  }
}
