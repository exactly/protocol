// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test, stdJson } from "forge-std/Test.sol";
import {
  ERC20,
  Market,
  Leverager,
  IBalancerVault,
  NotBalancerVault,
  FlashloanCallback
} from "../../contracts/periphery/Leverager.sol";
import { Auditor, InsufficientAccountLiquidity, MarketNotListed } from "../../contracts/Auditor.sol";

contract LeveragerTest is Test {
  using stdJson for string;

  Leverager internal leverager;
  Market internal marketUSDC;
  ERC20 internal usdc;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 84_666_000);

    usdc = ERC20(deployment("USDC"));
    marketUSDC = Market(deployment("MarketUSDC"));
    leverager = new Leverager(Auditor(deployment("Auditor")), IBalancerVault(deployment("BalancerVault")));

    deal(address(usdc), address(this), 100_000e6);
    marketUSDC.approve(address(leverager), type(uint256).max);
    usdc.approve(address(leverager), type(uint256).max);
  }

  function testLeverage() external {
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18, true);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertEq(marketUSDC.maxWithdraw(address(this)), 510153541353);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 410153541355);
  }

  function testLeverageWithAlreadyDepositedAmount() external {
    usdc.approve(address(marketUSDC), type(uint256).max);
    marketUSDC.deposit(100_000e6, address(this));
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18, false);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertEq(marketUSDC.maxWithdraw(address(this)), 510153541352);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 410153541355);
  }

  function testLeverageShouldFailWhenHealthFactorNearOne() external {
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    leverager.leverage(marketUSDC, 100_000e6, 1.000000000001e18, true);

    leverager.leverage(marketUSDC, 100_000e6, 1.00000000001e18, true);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertEq(marketUSDC.maxWithdraw(address(this)), 581733565996);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 481733565998);
  }

  function testDeleverage() external {
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18, true);
    leverager.deleverage(marketUSDC, 1e18);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    // precision loss (2)
    assertEq(marketUSDC.maxWithdraw(address(this)), 100_000e6 - 2);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 0);
  }

  function testDeleverageHalfBorrowPosition() external {
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18, true);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    uint256 leveragedDeposit = 510153541353;
    uint256 leveragedBorrow = 410153541355;
    assertEq(marketUSDC.maxWithdraw(address(this)), leveragedDeposit);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), leveragedBorrow);

    leverager.deleverage(marketUSDC, 0.5e18);
    (, , floatingBorrowShares) = marketUSDC.accounts(address(this));
    uint256 deleveragedDeposit = 305076770676;
    uint256 deleveragedBorrow = 205076770678;
    assertEq(marketUSDC.maxWithdraw(address(this)), deleveragedDeposit);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), deleveragedBorrow);
    assertEq(leveragedDeposit - deleveragedDeposit, leveragedBorrow - deleveragedBorrow);
  }

  function testFlashloanFeeGreaterThanZero() external {
    vm.prank(0xacAaC3e6D6Df918Bf3c809DFC7d42de0e4a72d4C);
    ProtocolFeesCollector(0xce88686553686DA562CE7Cea497CE749DA109f9F).setFlashLoanFeePercentage(1e15);

    vm.expectRevert("BAL#602");
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18, true);
  }

  function testApproveMarket() external {
    vm.expectEmit(true, true, true, true);
    emit Approval(address(leverager), address(marketUSDC), type(uint256).max);
    leverager.approve(marketUSDC);
    assertEq(usdc.allowance(address(leverager), address(marketUSDC)), type(uint256).max);
  }

  function testApproveMaliciousMarket() external {
    vm.expectRevert(MarketNotListed.selector);
    leverager.approve(Market(address(this)));
  }

  function testCallReceiveFlashLoanFromAnyAddress() external {
    uint256[] memory amounts = new uint256[](1);
    uint256[] memory feeAmounts = new uint256[](1);
    ERC20[] memory assets = new ERC20[](1);

    vm.expectRevert(NotBalancerVault.selector);
    leverager.receiveFlashLoan(assets, amounts, feeAmounts, "");
  }

  function testLeverageWithInvalidBalancerVault() external {
    Leverager lev = new Leverager(marketUSDC.auditor(), IBalancerVault(address(this)));
    vm.expectRevert(bytes(""));
    lev.leverage(marketUSDC, 100_000e6, 1.03e18, true);
  }

  function deployment(string memory name) internal returns (address addr) {
    addr = vm.readFile(string.concat("deployments/optimism/", name, ".json")).readAddress(".address");
    vm.label(addr, name);
  }

  event Approval(address indexed owner, address indexed spender, uint256 amount);
}

interface ProtocolFeesCollector {
  function setFlashLoanFeePercentage(uint256) external;
}
