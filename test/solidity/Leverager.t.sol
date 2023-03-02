// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test, stdJson } from "forge-std/Test.sol";
import { Leverager, Market, ERC20, IBalancerVault } from "../../contracts/periphery/Leverager.sol";
import { Auditor, InsufficientAccountLiquidity } from "../../contracts/Auditor.sol";

contract LeveragerTest is Test {
  using stdJson for string;

  Leverager internal leverager;
  Market internal marketUSDC;
  ERC20 internal usdc;

  function setUp() public {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 78444171);

    usdc = ERC20(getAddress("USDC"));
    marketUSDC = Market(getAddress("MarketUSDC"));
    leverager = new Leverager(Auditor(getAddress("Auditor")), IBalancerVault(getAddress("BalancerVault")));

    deal(address(usdc), address(this), 100_000e6);
    marketUSDC.approve(address(leverager), type(uint256).max);
    usdc.approve(address(leverager), type(uint256).max);
    leverager.approve(marketUSDC);
  }

  function testLeverage() public {
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertEq(marketUSDC.maxWithdraw(address(this)), 510153541353);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 410153541355);
  }

  function testLeverageShouldFailWhenHealthFactorNearOne() public {
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    leverager.leverage(marketUSDC, 100_000e6, 1.000000000001e18);

    leverager.leverage(marketUSDC, 100_000e6, 1.00000000001e18);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertEq(marketUSDC.maxWithdraw(address(this)), 581733565996);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 481733565998);
  }

  function testDeleverage() public {
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18);
    leverager.deleverage(marketUSDC, 1e18);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    // precision loss (2) :)
    assertEq(marketUSDC.maxWithdraw(address(this)), 100_000e6 - 2);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 0);
  }

  function testDeleverageHalfBorrowPosition() public {
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    uint256 leveragedDeposit = 510153541353;
    uint256 leveragedBorrow = 410153541355;
    assertEq(marketUSDC.maxWithdraw(address(this)), leveragedDeposit);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), leveragedBorrow);

    leverager.deleverage(marketUSDC, 0.5e18);
    (, , floatingBorrowShares) = marketUSDC.accounts(address(this));
    uint256 deleveragedDeposit = 305076770675;
    uint256 deleveragedBorrow = 205076770677;
    assertEq(marketUSDC.maxWithdraw(address(this)), deleveragedDeposit);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), deleveragedBorrow);
    assertEq(leveragedDeposit - deleveragedDeposit, leveragedBorrow - deleveragedBorrow);
  }

  function getAddress(string memory name) internal returns (address addr) {
    addr = vm.readFile(string.concat("deployments/optimism/", name, ".json")).readAddress(".address");
    vm.label(addr, name);
  }
}
