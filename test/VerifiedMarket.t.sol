// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { Test } from "forge-std/Test.sol";

import { Auditor } from "../contracts/Auditor.sol";
import { InterestRateModel } from "../contracts/InterestRateModel.sol";
import { Firewall } from "../contracts/verified/Firewall.sol";
import { NotAllowed, VerifiedAuditor } from "../contracts/verified/VerifiedAuditor.sol";
import { VerifiedMarket } from "../contracts/verified/VerifiedMarket.sol";

import { MockInterestRateModel } from "../contracts/mocks/MockInterestRateModel.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import { FixedLib } from "../contracts/utils/FixedLib.sol";

contract VerifiedMarketTest is Test {
  using FixedPointMathLib for uint256;

  uint256 public immutable lendersIncentive = 0.01e18;
  uint256 public immutable liquidatorIncentive = 0.09e18;

  MockERC20 public weth;
  MockERC20 public usdc;
  VerifiedAuditor public auditor;
  VerifiedMarket public marketWETH;
  VerifiedMarket public marketUSDC;
  Firewall public firewall;
  MockInterestRateModel public irm;
  MockPriceFeed public marketWETHPriceFeed;

  address public bob = makeAddr("bob");

  function setUp() public {
    weth = new MockERC20("Asset", "ASSET", 18);
    usdc = new MockERC20("USD Coin", "USDC", 6);
    firewall = Firewall(address(new ERC1967Proxy(address(new Firewall()), "")));
    firewall.initialize();
    firewall.grantRole(firewall.GRANTER_ROLE(), address(this));
    firewall.allow(address(this), true);
    vm.label(address(firewall), "Firewall");

    auditor = VerifiedAuditor(address(new ERC1967Proxy(address(new VerifiedAuditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(uint128(liquidatorIncentive), uint128(lendersIncentive)), firewall);
    vm.label(address(auditor), "Auditor");

    marketWETH = VerifiedMarket(address(new ERC1967Proxy(address(new VerifiedMarket(weth, auditor)), "")));
    marketWETH.initialize(
      3,
      1e18,
      InterestRateModel(address(new MockInterestRateModel(0.1e18))),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    vm.label(address(marketWETH), "MarketWETH");

    marketUSDC = VerifiedMarket(address(new ERC1967Proxy(address(new VerifiedMarket(usdc, auditor)), "")));
    marketUSDC.initialize(
      3,
      1e18,
      InterestRateModel(address(new MockInterestRateModel(0.1e18))),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    vm.label(address(marketUSDC), "MarketUSDC");

    marketWETHPriceFeed = new MockPriceFeed(18, 3_500e18);
    auditor.enableMarket(marketWETH, marketWETHPriceFeed, 0.86e18);
    auditor.enableMarket(marketUSDC, new MockPriceFeed(18, 1e18), 0.91e18);

    weth.mint(address(this), 1000 ether);
    weth.approve(address(marketWETH), type(uint256).max);
    usdc.mint(address(this), 1_000_000e6);
    usdc.approve(address(marketUSDC), type(uint256).max);
    usdc.mint(bob, 1_000_000e6);
  }

  // solhint-disable func-name-mixedcase

  function test_borrow_borrows_whenBorrowerIsAllowed() external {
    marketWETH.deposit(100 ether, address(this));

    marketWETH.borrow(10 ether, bob, address(this));

    assertEq(weth.balanceOf(bob), 10 ether);
  }

  function test_borrow_reverts_withNotAllowed_whenBorrowerIsNotAllowed() external {
    firewall.allow(bob, true);
    marketWETH.deposit(100 ether, bob);

    firewall.allow(bob, false);
    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.borrow(10 ether, address(this), bob);
  }

  function test_borrowAtMaturity_borrows_whenBorrowerIsAllowed() external {
    marketWETH.deposit(100 ether, address(this));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, 11 ether, bob, address(this));
    assertEq(weth.balanceOf(bob), 10 ether);
  }

  function test_borrowAtMaturity_reverts_withNotAllowed_whenBorrowerIsNotAllowed() external {
    firewall.allow(bob, true);
    marketWETH.deposit(100 ether, bob);
    firewall.allow(bob, false);

    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, 11 ether, bob, bob);
  }

  function test_deposit_deposits_whenSenderAndReceiverAreAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    assertEq(marketWETH.maxWithdraw(address(this)), 10 ether);

    firewall.allow(bob, true);
    marketWETH.deposit(10 ether, bob);
    assertEq(marketWETH.maxWithdraw(bob), 10 ether);
  }

  function test_mint_mints_whenSenderAndReceiverAreAllowed() external {
    marketWETH.mint(10 ether, address(this));
    assertEq(marketWETH.balanceOf(address(this)), 10 ether);

    firewall.allow(bob, true);
    marketWETH.mint(10 ether, bob);
    assertEq(marketWETH.balanceOf(bob), 10 ether);
  }

  function test_deposit_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    weth.mint(bob, 10 ether);

    vm.startPrank(bob);
    weth.approve(address(marketWETH), 10 ether);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.deposit(10 ether, address(this));
  }

  function test_deposit_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.deposit(10 ether, bob);
  }

  function test_deposit_revert_withNotAllowed_whenBothSenderAndReceiverAreNotAllowed() external {
    weth.mint(bob, 10 ether);

    vm.startPrank(bob);
    weth.approve(address(marketWETH), 10 ether);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.deposit(10 ether, bob);
  }

  function test_mint_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    weth.mint(bob, 10 ether);

    vm.startPrank(bob);
    weth.approve(address(marketWETH), 10 ether);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.mint(10 ether, address(this));
  }

  function test_mint_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.mint(10 ether, bob);
  }

  function test_mint_revert_withNotAllowed_whenBothSenderAndReceiverAreNotAllowed() external {
    weth.mint(bob, 10 ether);

    vm.startPrank(bob);
    weth.approve(address(marketWETH), 10 ether);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.mint(10 ether, bob);
  }

  function test_depositAtMaturity_deposits_whenSenderAndReceiverAreAllowed() external {
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, address(this));

    (uint256 principal, ) = marketWETH.fixedDepositPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal, 10 ether);

    firewall.allow(bob, true);
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, bob);
    (principal, ) = marketWETH.fixedDepositPositions(FixedLib.INTERVAL, bob);
    assertEq(principal, 10 ether);
  }

  function test_depositAtMaturity_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, address(this));
  }

  function test_depositAtMaturity_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, bob);
  }

  function test_redeem_redeems_whenSenderIsAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    firewall.allow(bob, true);
    uint256 assets = marketWETH.redeem(10 ether, bob, address(this));
    assertEq(weth.balanceOf(bob), assets);
  }

  function test_redeem_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    firewall.allow(bob, true);
    marketWETH.deposit(10 ether, bob);
    firewall.allow(bob, false);

    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.redeem(10 ether, address(this), bob);
  }

  function test_transfer_transfers_whenSenderAndReceiverAreAllowed() external {
    marketWETH.deposit(10 ether, address(this));

    firewall.allow(bob, true);
    marketWETH.transfer(bob, 10 ether);
    assertEq(marketWETH.maxWithdraw(bob), 10 ether);
  }

  function test_transfer_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));

    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.transfer(bob, 10 ether);
  }

  function test_transfer_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    firewall.allow(bob, true);
    marketWETH.deposit(10 ether, bob);
    firewall.allow(bob, false);

    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.transfer(address(this), 10 ether);
  }

  function test_transfer_reverts_withNotAllowed_whenBothSenderAndReceiverAreNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));

    firewall.allow(address(this), false);

    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.transfer(bob, 10 ether);
  }

  function test_transferFrom_transfers_whenSenderAndReceiverAreAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    firewall.allow(bob, true);

    marketWETH.approve(bob, 10 ether);
    vm.startPrank(bob);
    marketWETH.transferFrom(address(this), bob, 10 ether);
    assertEq(marketWETH.maxWithdraw(bob), 10 ether);
  }

  function test_transferFrom_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.transferFrom(address(this), bob, 10 ether);
  }

  function test_transferFrom_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    firewall.allow(bob, true);
    marketWETH.deposit(10 ether, bob);
    firewall.allow(bob, false);

    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.transferFrom(bob, address(this), 10 ether);
  }

  function test_transferFrom_reverts_withNotAllowed_whenBothSenderAndReceiverAreNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    firewall.allow(address(this), false);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.transferFrom(address(this), bob, 10 ether);
  }

  function test_withdraw_withdraws_whenSenderIsAllowed() external {
    marketWETH.deposit(10 ether, address(this));
    uint256 balance = weth.balanceOf(bob);
    marketWETH.withdraw(10 ether, bob, address(this));
    assertEq(weth.balanceOf(bob), balance + 10 ether);
  }

  function test_withdraw_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    firewall.allow(bob, true);
    marketWETH.deposit(10 ether, bob);
    firewall.allow(bob, false);

    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.withdraw(10 ether, address(this), bob);
  }

  function test_withdrawAtMaturity_withdraws_whenOwnerIsAllowed() external {
    firewall.allow(bob, true);
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, bob);

    skip(FixedLib.INTERVAL);
    vm.startPrank(bob);
    marketWETH.withdrawAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, bob, bob);

    (uint256 principal, ) = marketWETH.fixedDepositPositions(FixedLib.INTERVAL, bob);
    assertEq(principal, 0);
    assertEq(weth.balanceOf(bob), 10 ether);
  }

  function test_withdrawAtMaturity_reverts_withNotAllowed_whenOwnerIsNotAllowed() external {
    firewall.allow(bob, true);
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, bob);

    skip(FixedLib.INTERVAL);
    firewall.allow(bob, false);
    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    marketWETH.withdrawAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, bob, bob);

    (uint256 principal, ) = marketWETH.fixedDepositPositions(FixedLib.INTERVAL, bob);
    assertEq(principal, 10 ether);
    assertEq(weth.balanceOf(bob), 0);
  }

  function test_liquidateAllowedAccount_liquidates_withIncentives() external {
    marketWETH.deposit(10 ether, address(this));

    firewall.allow(bob, true);
    marketUSDC.deposit(5_000e6, bob);

    vm.startPrank(bob);
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(1 ether, bob, bob);
    vm.stopPrank();

    uint256 usdcBefore = usdc.balanceOf(address(this));
    assertEq(marketWETH.earningsAccumulator(), 0);

    marketWETHPriceFeed.setPrice(4_000e18);
    uint256 repaidAssets = marketWETH.liquidate(bob, 1 ether, marketUSDC);

    assertEq(
      marketWETH.earningsAccumulator(),
      repaidAssets.mulWadDown(lendersIncentive),
      "10% incentive to lenders != expected"
    );
    assertEq(
      usdc.balanceOf(address(this)) - usdcBefore + marketUSDC.maxWithdraw(bob),
      5_000e6,
      "usdc didn't go to liquidator"
    );
  }

  function test_liquidateNotAllowedAccount_liquidates_withoutIncentives() external {
    marketWETH.deposit(10 ether, address(this));

    firewall.allow(bob, true);
    marketUSDC.deposit(5_000e6, bob);

    vm.startPrank(bob);
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(1 ether, bob, bob);
    vm.stopPrank();

    firewall.allow(bob, false);

    uint256 repaidAssets = marketWETH.liquidate(bob, 1 ether, marketUSDC);
    assertEq(marketWETH.earningsAccumulator(), 0, "lenders got incentives");
    assertEq(repaidAssets, 1 ether, "deb't didn't repay in full");
    assertEq(marketWETH.previewDebt(bob), 0, "position not closed");
    assertEq(marketUSDC.maxWithdraw(bob), 5_000e6 - 3_500e6, "collateral left"); // eth price is 3_500e18
  }

  function test_liquidateNotAllowedAccount_underwater_liquidates_withoutIncentives() external {
    marketWETH.deposit(10 ether, address(this));

    firewall.allow(bob, true);
    marketUSDC.deposit(5_000e6, bob);

    vm.startPrank(bob);
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(1 ether, bob, bob);
    vm.stopPrank();

    firewall.allow(bob, false);

    marketWETHPriceFeed.setPrice(4_000e18);
    uint256 repaidAssets = marketWETH.liquidate(bob, 1 ether, marketUSDC);

    assertEq(marketWETH.earningsAccumulator(), 0, "lenders got incentives");
    assertEq(repaidAssets, 1 ether, "deb't didn't repay in full");
    assertEq(marketWETH.previewDebt(bob), 0, "position not closed");
    assertEq(marketUSDC.maxWithdraw(bob), 5_000e6 - 4_000e6, "collateral left");
  }

  function test_liquidate_reverts_withNotAllowed_whenLiquidatorIsNotAllowed() external {
    marketWETH.deposit(10 ether, address(this));

    firewall.allow(bob, true);
    marketUSDC.deposit(5_000e6, bob);

    vm.startPrank(bob);
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(1 ether, bob, bob);
    vm.stopPrank();

    marketWETHPriceFeed.setPrice(6_000e18);

    firewall.allow(address(this), false);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, address(this)));
    marketWETH.liquidate(bob, 1 ether, marketUSDC);
  }

  // solhint-enable func-name-mixedcase
}
