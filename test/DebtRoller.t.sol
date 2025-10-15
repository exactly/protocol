// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0; // solhint-disable-line one-contract-per-file

import { Test } from "forge-std/Test.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

import { InterestRateModel, FixedLib } from "../contracts/InterestRateModel.sol";
import {
  Auditor,
  Market,
  DebtRoller,
  IFlashLoaner,
  NotMarket,
  InvalidOperation
} from "../contracts/periphery/DebtRoller.sol";
import { MockBalancerVault } from "../contracts/mocks/MockBalancerVault.sol";
import { MockInterestRateModel } from "../contracts/mocks/MockInterestRateModel.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";

contract DebtRollerTest is Test {
  Auditor internal auditor;
  Market internal exaUSDC;
  MockERC20 internal usdc;
  DebtRoller internal debtRoller;
  MockBalancerVault internal mockBalancerVault;

  function setUp() external {
    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    vm.label(address(auditor), "Auditor");

    usdc = new MockERC20("USD Coin", "USDC", 6);
    exaUSDC = Market(address(new ERC1967Proxy(address(new Market(usdc, auditor)), "")));
    exaUSDC.initialize(
      "USDC",
      3,
      1e18,
      InterestRateModel(address(new MockInterestRateModel(0.1e18))),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    vm.label(address(exaUSDC), "exaUSDC");
    vm.label(address(usdc), "usdc");

    auditor.enableMarket(exaUSDC, new MockPriceFeed(18, 1e18), 0.8e18);

    mockBalancerVault = new MockBalancerVault();
    vm.label(address(mockBalancerVault), "mockBalancerVault");
    mockBalancerVault.setFee(1);

    debtRoller = DebtRoller(
      address(new ERC1967Proxy(address(new DebtRoller(auditor, IFlashLoaner(address(mockBalancerVault)))), ""))
    );
    debtRoller.initialize();
    vm.label(address(debtRoller), "debtRoller");

    usdc.mint(address(mockBalancerVault), 1_000_000e6);
  }

  // solhint-disable func-name-mixedcase

  function test_rollFixed_rolls() external {
    deposit(100_000e6);

    uint256 borrowAmount = 50_000e6;
    exaUSDC.borrowAtMaturity(FixedLib.INTERVAL, borrowAmount, borrowAmount * 2, address(this), address(this));

    (uint256 principal, ) = exaUSDC.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal, borrowAmount);
    (uint256 principal2, ) = exaUSDC.fixedBorrowPositions(FixedLib.INTERVAL * 2, address(this));
    assertEq(principal2, 0);

    exaUSDC.approve(address(debtRoller), borrowAmount * 2);
    debtRoller.rollFixed(exaUSDC, FixedLib.INTERVAL, FixedLib.INTERVAL * 2, borrowAmount * 2, borrowAmount * 2, 1e18);

    (principal, ) = exaUSDC.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal, 0);
    (principal2, ) = exaUSDC.fixedBorrowPositions(FixedLib.INTERVAL * 2, address(this));
    assertGt(principal2, 0);
  }

  function test_rollFixed_rolls_partial() external {
    deposit(100_000e6);

    uint256 borrowAmount = 50_000e6;
    exaUSDC.borrowAtMaturity(FixedLib.INTERVAL, borrowAmount, borrowAmount * 2, address(this), address(this));

    (uint256 principal, ) = exaUSDC.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal, borrowAmount);
    (uint256 principal2, ) = exaUSDC.fixedBorrowPositions(FixedLib.INTERVAL * 2, address(this));
    assertEq(principal2, 0);

    exaUSDC.approve(address(debtRoller), borrowAmount * 2);
    debtRoller.rollFixed(exaUSDC, FixedLib.INTERVAL, FixedLib.INTERVAL * 2, borrowAmount * 2, borrowAmount * 2, 0.5e18);

    (principal, ) = exaUSDC.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal, borrowAmount / 2);
    (principal2, ) = exaUSDC.fixedBorrowPositions(FixedLib.INTERVAL * 2, address(this));
    assertGt(principal2, borrowAmount / 2);
  }

  function test_rollFixed_reverts_whenNotMarket() external {
    vm.expectRevert(NotMarket.selector);
    debtRoller.rollFixed(Market(address(this)), FixedLib.INTERVAL, FixedLib.INTERVAL * 2, 1, 1, 1e18);
  }

  function test_rollFixed_reverts_whenInvalidOperation() external {
    vm.expectRevert(InvalidOperation.selector);
    debtRoller.rollFixed(exaUSDC, FixedLib.INTERVAL, FixedLib.INTERVAL, 1, 1, 1e18);
  }

  // solhint-enable func-name-mixedcase

  function deposit(uint256 amount) internal {
    usdc.mint(address(this), amount);
    usdc.approve(address(exaUSDC), amount);
    exaUSDC.deposit(amount, address(this));
  }
}
