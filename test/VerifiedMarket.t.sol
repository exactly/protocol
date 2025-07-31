// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
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
  MockERC20 public asset;
  VerifiedAuditor public auditor;
  VerifiedMarket public market;
  Firewall public firewall;
  MockInterestRateModel public irm;
  MockPriceFeed public marketPriceFeed;

  address public bob = makeAddr("bob");

  function setUp() public {
    asset = new MockERC20("Asset", "ASSET", 18);
    firewall = Firewall(address(new ERC1967Proxy(address(new Firewall()), "")));
    firewall.initialize();
    firewall.grantRole(firewall.GRANTER_ROLE(), address(this));
    firewall.allow(address(this), true);
    vm.label(address(firewall), "Firewall");

    auditor = VerifiedAuditor(address(new ERC1967Proxy(address(new VerifiedAuditor(18)), "")));
    auditor.initializeVerified(Auditor.LiquidationIncentive(0.09e18, 0.01e18), firewall);
    vm.label(address(auditor), "Auditor");

    market = VerifiedMarket(address(new ERC1967Proxy(address(new VerifiedMarket(asset, auditor)), "")));
    market.initialize(
      "ASSET",
      3,
      1e18,
      InterestRateModel(address(new MockInterestRateModel(0.1e18))),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    vm.label(address(market), "Market");

    marketPriceFeed = new MockPriceFeed(18, 2e18);
    auditor.enableMarket(market, marketPriceFeed, 0.8e18);

    asset.mint(address(this), 1000 ether);
    asset.approve(address(market), type(uint256).max);
  }

  // solhint-disable func-name-mixedcase

  function test_borrow_borrows_whenBorrowerIsAllowed() external {
    market.deposit(100 ether, address(this));

    market.borrow(10 ether, bob, address(this));

    assertEq(asset.balanceOf(bob), 10 ether);
  }

  function test_borrow_reverts_withNotAllowed_whenBorrowerIsNotAllowed() external {
    firewall.allow(bob, true);
    market.deposit(100 ether, bob);

    firewall.allow(bob, false);
    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.borrow(10 ether, address(this), bob);
  }

  function test_borrowAtMaturity_borrows_whenBorrowerIsAllowed() external {
    market.deposit(100 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, 11 ether, bob, address(this));
    assertEq(asset.balanceOf(bob), 10 ether);
  }

  function test_borrowAtMaturity_reverts_withNotAllowed_whenBorrowerIsNotAllowed() external {
    firewall.allow(bob, true);
    market.deposit(100 ether, bob);
    firewall.allow(bob, false);

    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, 11 ether, bob, bob);
  }

  function test_deposit_deposits_whenSenderAndReceiverAreAllowed() external {
    market.deposit(10 ether, address(this));
    assertEq(market.maxWithdraw(address(this)), 10 ether);

    firewall.allow(bob, true);
    market.deposit(10 ether, bob);
    assertEq(market.maxWithdraw(bob), 10 ether);
  }

  function test_mint_mints_whenSenderAndReceiverAreAllowed() external {
    market.mint(10 ether, address(this));
    assertEq(market.balanceOf(address(this)), 10 ether);

    firewall.allow(bob, true);
    market.mint(10 ether, bob);
    assertEq(market.balanceOf(bob), 10 ether);
  }

  function test_deposit_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    asset.mint(bob, 10 ether);

    vm.startPrank(bob);
    asset.approve(address(market), 10 ether);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.deposit(10 ether, address(this));
  }

  function test_deposit_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.deposit(10 ether, bob);
  }

  function test_deposit_revert_withNotAllowed_whenBothSenderAndReceiverAreNotAllowed() external {
    asset.mint(bob, 10 ether);

    vm.startPrank(bob);
    asset.approve(address(market), 10 ether);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.deposit(10 ether, bob);
  }

  function test_mint_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    asset.mint(bob, 10 ether);

    vm.startPrank(bob);
    asset.approve(address(market), 10 ether);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.mint(10 ether, address(this));
  }

  function test_mint_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.mint(10 ether, bob);
  }

  function test_mint_revert_withNotAllowed_whenBothSenderAndReceiverAreNotAllowed() external {
    asset.mint(bob, 10 ether);

    vm.startPrank(bob);
    asset.approve(address(market), 10 ether);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.mint(10 ether, bob);
  }

  function test_depositAtMaturity_deposits_whenSenderAndReceiverAreAllowed() external {
    market.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, address(this));

    (uint256 principal, ) = market.fixedDepositPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal, 10 ether);

    firewall.allow(bob, true);
    market.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, bob);
    (principal, ) = market.fixedDepositPositions(FixedLib.INTERVAL, bob);
    assertEq(principal, 10 ether);
  }

  function test_depositAtMaturity_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, address(this));
  }

  function test_depositAtMaturity_reverts_withNotAllowed_whenReceiverIsNotAllowed() external {
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, bob);
  }

  function test_redeem_redeems_whenSenderIsAllowed() external {
    market.deposit(10 ether, address(this));
    firewall.allow(bob, true);
    uint256 assets = market.redeem(10 ether, bob, address(this));
    assertEq(asset.balanceOf(bob), assets);
  }

  function test_redeem_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    firewall.allow(bob, true);
    market.deposit(10 ether, bob);
    firewall.allow(bob, false);

    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.redeem(10 ether, address(this), bob);
  }

  function test_withdraw_withdraws_whenSenderIsAllowed() external {
    market.deposit(10 ether, address(this));
    uint256 balance = asset.balanceOf(bob);
    market.withdraw(10 ether, bob, address(this));
    assertEq(asset.balanceOf(bob), balance + 10 ether);
  }

  function test_withdraw_reverts_withNotAllowed_whenSenderIsNotAllowed() external {
    firewall.allow(bob, true);
    market.deposit(10 ether, bob);
    firewall.allow(bob, false);

    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.withdraw(10 ether, address(this), bob);
  }

  function test_withdrawAtMaturity_withdraws_whenOwnerIsAllowed() external {
    firewall.allow(bob, true);
    market.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, bob);

    skip(FixedLib.INTERVAL);
    vm.startPrank(bob);
    market.withdrawAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, bob, bob);

    (uint256 principal, ) = market.fixedDepositPositions(FixedLib.INTERVAL, bob);
    assertEq(principal, 0);
    assertEq(asset.balanceOf(bob), 10 ether);
  }

  function test_withdrawAtMaturity_reverts_withNotAllowed_whenOwnerIsNotAllowed() external {
    firewall.allow(bob, true);
    market.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, bob);

    skip(FixedLib.INTERVAL);
    firewall.allow(bob, false);
    vm.startPrank(bob);
    vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, bob));
    market.withdrawAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, bob, bob);

    (uint256 principal, ) = market.fixedDepositPositions(FixedLib.INTERVAL, bob);
    assertEq(principal, 10 ether);
    assertEq(asset.balanceOf(bob), 0);
  }

  // solhint-enable func-name-mixedcase
}
