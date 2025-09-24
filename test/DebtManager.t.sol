// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17; // solhint-disable-line one-contract-per-file

import { ForkTest, stdJson, stdError } from "./Fork.t.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC4626 } from "solmate/src/mixins/ERC4626.sol";
import {
  ERC20,
  Permit,
  Permit2,
  IPermit2,
  DebtManager,
  IBalancerVault,
  InvalidOperation,
  AllowanceSurplus
} from "../contracts/periphery/DebtManager.sol";
import { Auditor, InsufficientAccountLiquidity, MarketNotListed, IPriceFeed } from "../contracts/Auditor.sol";
import { FixedLib, UnmatchedPoolState } from "../contracts/utils/FixedLib.sol";
import { MockBalancerVault } from "../contracts/mocks/MockBalancerVault.sol";
import { Market, Disagreement, ZeroRepay } from "../contracts/Market.sol";
import { FlashLoanAdapter } from "../contracts/periphery/FlashLoanAdapter.sol";

contract DebtManagerTest is ForkTest {
  using FixedPointMathLib for uint256;
  using FixedLib for FixedLib.Position;
  using FixedLib for FixedLib.Pool;
  using stdJson for string;

  uint160 internal constant MIN_SQRT_RATIO = 4295128739;
  uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
  uint256 internal constant BOB_KEY = 0xb0b;
  address internal bob;
  Auditor internal auditor;
  IPermit2 internal permit2;
  DebtManager internal debtManager;
  Market internal marketOP;
  Market internal marketUSDC;
  Market internal marketWETH;
  Market internal marketwstETH;
  ERC20 internal op;
  ERC20 internal weth;
  ERC20 internal usdc;
  ERC20 internal wstETH;
  uint256 internal maturity;
  uint256 internal targetMaturity;
  FlashLoanAdapter internal flashLoanAdapter;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 99_811_375);

    op = ERC20(deployment("OP"));
    weth = ERC20(deployment("WETH"));
    usdc = ERC20(deployment("USDC.e"));
    wstETH = ERC20(deployment("wstETH"));

    marketOP = Market(deployment("MarketOP"));
    // upgrade(
    //   deployment("MarketOP"),
    //   address(new Market(Market(deployment("MarketOP")).asset(), Auditor(deployment("Auditor"))))
    // );
    marketUSDC = Market(deployment("MarketUSDC.e"));
    // upgrade(
    //   deployment("MarketUSDC.e"),
    //   address(new Market(Market(deployment("MarketUSDC.e")).asset(), Auditor(deployment("Auditor"))))
    // );
    marketWETH = Market(deployment("MarketWETH"));
    // upgrade(
    //   deployment("MarketWETH"),
    //   address(new Market(Market(deployment("MarketWETH")).asset(), Auditor(deployment("Auditor"))))
    // );
    marketwstETH = Market(deployment("MarketwstETH"));
    // upgrade(
    //   deployment("MarketwstETH"),
    //   address(new Market(Market(deployment("MarketwstETH")).asset(), Auditor(deployment("Auditor"))))
    // );

    auditor = Auditor(deployment("Auditor"));
    permit2 = IPermit2(deployment("Permit2"));

    // flashLoanAdapter = new FlashLoanAdapter(auditor);
    // vm.label(address(flashLoanAdapter), "FlashLoanAdapter");

    debtManager = DebtManager(
      address(
        new ERC1967Proxy(
          // address(new DebtManager(auditor, permit2, IBalancerVault(address(flashLoanAdapter)))),
          address(new DebtManager(auditor, permit2, IBalancerVault(deployment("BalancerVault")))),
          abi.encodeCall(DebtManager.initialize, ())
        )
      )
    );
    vm.label(address(debtManager), "DebtManager");
    assertLt(usdc.balanceOf(address(debtManager.balancerVault())), 1_000_000e6);

    deal(address(usdc), address(this), 22_000_000e6);
    deal(address(weth), address(this), 1_000e18);
    deal(address(wstETH), address(this), 1_000e18);
    marketUSDC.approve(address(debtManager), type(uint256).max);
    marketWETH.approve(address(debtManager), type(uint256).max);
    marketwstETH.approve(address(debtManager), type(uint256).max);
    usdc.approve(address(marketUSDC), type(uint256).max);
    usdc.approve(address(debtManager), type(uint256).max);
    wstETH.approve(address(marketwstETH), type(uint256).max);
    wstETH.approve(address(debtManager), type(uint256).max);

    maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    targetMaturity = maturity + FixedLib.INTERVAL;

    bob = vm.addr(BOB_KEY);
    vm.prank(bob);
    usdc.approve(address(permit2), type(uint256).max);
    deal(address(usdc), bob, 100_000e6);
    vm.label(bob, "bob");
  }

  function testFuzzRolls(
    uint8[4] calldata i,
    uint8[4] calldata j,
    uint256[4] calldata percentages,
    uint40[4] calldata amounts,
    uint8[4] calldata times
  ) external _checkBalances {
    marketUSDC.deposit(20_000_000e6, address(this));
    usdc.transfer(address(debtManager), 1);
    vm.warp(block.timestamp + 10_000);
    uint256 pastMaturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL);

    for (uint256 k = 0; k < 4; ++k) {
      // solhint-disable-next-line reentrancy
      maturity = pastMaturity + FixedLib.INTERVAL * _bound(i[k], 1, marketUSDC.maxFuturePools());
      // solhint-disable-next-line reentrancy
      targetMaturity = pastMaturity + FixedLib.INTERVAL * _bound(j[k], 1, marketUSDC.maxFuturePools());
      uint256 percentage = _bound(percentages[k], 0, 1.1e18);

      marketUSDC.borrow(amounts[k], address(this), address(this));
      if (block.timestamp < maturity && amounts[k] > 0) {
        marketUSDC.borrowAtMaturity(maturity, amounts[k], type(uint256).max, address(this), address(this));
      }

      checkRevert(percentage, Operation.FloatingToFixed);
      debtManager.rollFloatingToFixed(marketUSDC, targetMaturity, type(uint256).max, percentage);

      checkRevert(percentage, Operation.FixedToFloating);
      debtManager.rollFixedToFloating(marketUSDC, maturity, type(uint256).max, percentage);

      checkRevert(percentage, Operation.FixedToFixed);
      debtManager.rollFixed(marketUSDC, maturity, targetMaturity, type(uint256).max, type(uint256).max, percentage);

      vm.warp(block.timestamp + uint256(times[k]) * 1 hours);
    }
  }

  function checkRevert(uint256 percentage, Operation operation) internal {
    uint256 repayAssets;
    if (operation == Operation.FloatingToFixed) {
      (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
      repayAssets = marketUSDC.previewRefund(floatingBorrowShares);
      if (percentage < 1e18) repayAssets = repayAssets.mulWadDown(percentage);
      if (repayAssets > 0 && marketUSDC.previewRepay(repayAssets) == 0) return vm.expectRevert(ZeroRepay.selector);
    } else {
      if (block.timestamp < maturity) {
        (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
        if (principal + fee == 0) return vm.expectRevert(bytes(""));
      }
      FixedLib.Position memory position;
      (position.principal, position.fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
      uint256 assets = percentage < 1e18
        ? percentage.mulWadDown(position.principal + position.fee)
        : position.principal + position.fee;
      if (block.timestamp < maturity) {
        FixedLib.Pool memory pool;
        (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = marketUSDC.fixedPools(maturity);
        pool.unassignedEarnings -= pool.unassignedEarnings.mulDivDown(
          block.timestamp - pool.lastAccrual,
          maturity - pool.lastAccrual
        );
        (uint256 yield, ) = pool.calculateDeposit(
          position.scaleProportionally(assets).principal,
          marketUSDC.backupFeeRate()
        );
        repayAssets = assets - yield;
      } else {
        repayAssets = assets + assets.mulWadDown((block.timestamp - maturity) * marketUSDC.penaltyRate());
      }
    }
    if (repayAssets == 0) {
      return vm.expectRevert(operation == Operation.FixedToFloating ? stdError.divisionError : bytes(""));
    }
    uint256 loopCount = repayAssets.mulDivUp(1, usdc.balanceOf(address(debtManager.balancerVault())));
    if (operation == Operation.FixedToFixed && maturity == targetMaturity && loopCount > 1) {
      return vm.expectRevert(InvalidOperation.selector);
    }
    if (operation != Operation.FixedToFloating && block.timestamp >= targetMaturity) {
      return
        vm.expectRevert(
          abi.encodeWithSelector(UnmatchedPoolState.selector, FixedLib.State.MATURED, FixedLib.State.VALID)
        );
    }
  }

  function testLeverage() external _checkBalances {
    uint256 principal = 100_000e6;
    uint256 ratio = 4e18;
    debtManager.leverage(marketUSDC, principal, ratio);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 1);
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 1);
  }

  function testLeverageWithNegativePrincipal() external _checkBalances {
    weth.approve(address(marketWETH), type(uint256).max);
    marketWETH.deposit(10 ether, address(this));
    auditor.enterMarket(marketWETH);
    marketUSDC.borrow(10_000e6, address(this), address(this));

    // current ratio is 6x
    debtManager.leverage(marketUSDC, 12_000e6, 6e18);
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), 12_000e6, 1);
  }

  function testLeverageWithPartialNegativePrincipal() external _checkBalances {
    weth.approve(address(marketWETH), type(uint256).max);
    marketWETH.deposit(10 ether, address(this));
    auditor.enterMarket(marketWETH);
    marketUSDC.deposit(2_000e6, address(this));
    marketUSDC.borrow(10_000e6, address(this), address(this));

    // current ratio is 6x
    debtManager.leverage(marketUSDC, 10_000e6, 6e18);
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), 12_000e6, 1);
  }

  function testLeverageIncremental() external _checkBalances {
    uint256 principal = 100_000e6;

    uint256 ratio = 2e18;
    debtManager.leverage(marketUSDC, principal, ratio);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 1);
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 1);

    ratio = 3e18;
    debtManager.leverage(marketUSDC, 0, ratio);
    (, , floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 6);
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 4);

    ratio = 4e18;
    debtManager.leverage(marketUSDC, 0, ratio);
    (, , floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 8);
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 6);
  }

  function testLeverageWithAlreadyDepositedAmount() external _checkBalances {
    uint256 principal = 100_000e6;
    uint256 ratio = 4.10153541354e18;
    usdc.approve(address(marketUSDC), type(uint256).max);
    marketUSDC.deposit(principal, address(this));
    debtManager.leverage(marketUSDC, 0, ratio);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 6);
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 4);
  }

  function testLeverageShouldFailWhenHealthFactorNearOne() external _checkBalances {
    uint256 principal = 100_000e6;
    vm.expectRevert(abi.encodeWithSelector(InsufficientAccountLiquidity.selector));
    debtManager.leverage(marketUSDC, principal, 5.82e18);

    uint256 ratio = 4.81733565997e18;
    debtManager.leverage(marketUSDC, principal, ratio);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 1);
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 1);
  }

  function testLeverageWithMoreThanBalancerAvailableLiquidity() external _checkBalances {
    uint256 principal = 1_000_000e6;
    uint256 ratio = 4.10153541354e18;
    debtManager.leverage(marketUSDC, principal, ratio);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 5);
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 3);
  }

  function testDeleverage() external _checkBalances {
    uint256 principal = 100_000e6;
    uint256 ratio = 4e18;
    debtManager.leverage(marketUSDC, principal, ratio);

    ratio = 3e18;
    debtManager.deleverage(marketUSDC, 0, ratio);

    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 7);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 3);
  }

  function testDeleverageIncremental() external _checkBalances {
    uint256 principal = 100_000e6;

    uint256 ratio = 4e18;
    debtManager.leverage(marketUSDC, principal, ratio);

    ratio = 3e18;
    debtManager.deleverage(marketUSDC, 0, ratio);
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 7);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 3);

    ratio = 2e18;
    debtManager.deleverage(marketUSDC, 0, ratio);
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 9);
    (, , floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 3);

    ratio = 1e18;
    debtManager.deleverage(marketUSDC, 0, ratio);
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 7);
    (, , floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 0);
  }

  function testDeleverageWithPartialWithdraw() external _checkBalances {
    debtManager.leverage(marketUSDC, 10_000e6, 3e18);
    debtManager.deleverage(marketUSDC, 5_000e6, 1e18);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 0);
    assertEq(marketUSDC.maxWithdraw(address(this)), 5_000e6 - 3);
  }

  function testDeleverageWithWithdraw() external _checkBalances {
    debtManager.leverage(marketUSDC, 100_000e6, 2e18);
    debtManager.deleverage(marketUSDC, 100_000e6 - 3, 1e18);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 0);
    assertEq(marketUSDC.maxWithdraw(address(this)), 0);
  }

  function testPartialDeleverageWithWithdrawKeepingRatio() external _checkBalances {
    uint256 principal = 100_000e6;
    uint256 ratio = 3e18;
    debtManager.leverage(marketUSDC, principal, ratio);

    debtManager.deleverage(marketUSDC, 50_000e6, ratio);
    principal -= 50_000e6;

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 8);
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 3);
  }

  function testPartialDeleverageWithWithdrawAndNewRatio() external _checkBalances {
    uint256 principal = 100_000e6;
    uint256 ratio = 3e18;
    debtManager.leverage(marketUSDC, principal, ratio);

    ratio = 2e18;
    debtManager.deleverage(marketUSDC, 20_000e6, ratio);
    principal -= 20_000e6;

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), principal.mulWadDown(ratio), 6);
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 2);
  }

  function testDeleverageHalfPosition() external _checkBalances {
    uint256 principal = 100_000e6;
    uint256 ratio = 4.2e18;
    debtManager.leverage(marketUSDC, 100_000e6, ratio);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    uint256 leveragedDeposit = marketUSDC.maxWithdraw(address(this));
    uint256 leveragedBorrow = marketUSDC.previewRefund(floatingBorrowShares);
    assertApproxEqAbs(leveragedDeposit, principal.mulWadDown(ratio), 1);
    assertApproxEqAbs(leveragedBorrow, principal.mulWadDown(ratio - 1e18), 1);

    ratio = 2.1e18;
    debtManager.deleverage(marketUSDC, 0, ratio);
    (, , floatingBorrowShares) = marketUSDC.accounts(address(this));
    uint256 halfDeleveragedDeposit = marketUSDC.maxWithdraw(address(this));
    uint256 halfDeleveragedBorrow = marketUSDC.previewRefund(floatingBorrowShares);
    assertApproxEqAbs(halfDeleveragedDeposit, principal.mulWadDown(ratio), 6);
    assertApproxEqAbs(halfDeleveragedBorrow, principal.mulWadDown(ratio - 1e18), 2);

    assertApproxEqAbs(leveragedDeposit.divWadDown(2e18), halfDeleveragedDeposit, 5);
  }

  function testDeleverageWithMoreThanBalancerAvailableLiquidity() external _checkBalances {
    debtManager.leverage(marketUSDC, 1_000_000e6, 2e18);
    debtManager.deleverage(marketUSDC, 0, 1e18);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), 1_000_000e6, 4);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 0);
  }

  function testFlashloanFeeGreaterThanZero() external {
    vm.prank(0xacAaC3e6D6Df918Bf3c809DFC7d42de0e4a72d4C);
    ProtocolFeesCollector(0xce88686553686DA562CE7Cea497CE749DA109f9F).setFlashLoanFeePercentage(1e15);

    vm.expectRevert("BAL#602");
    debtManager.leverage(marketUSDC, 100_000e6, 1.03e18);
  }

  function testApproveMarket() external {
    vm.expectEmit(true, true, true, true);
    emit Approval(address(debtManager), address(marketUSDC), type(uint256).max);
    debtManager.approve(marketUSDC);
    assertEq(usdc.allowance(address(debtManager), address(marketUSDC)), type(uint256).max);
  }

  function testApproveMaliciousMarket() external {
    vm.expectRevert(MarketNotListed.selector);
    debtManager.approve(Market(address(this)));
  }

  function testCallReceiveFlashLoanFromAnyAddress() external _checkBalances {
    uint256[] memory amounts = new uint256[](1);
    uint256[] memory feeAmounts = new uint256[](1);
    ERC20[] memory assets = new ERC20[](1);

    vm.expectRevert(stdError.assertionError);
    debtManager.receiveFlashLoan(assets, amounts, feeAmounts, "");
  }

  function testLeverageWithInvalidBalancerVault() external {
    DebtManager lev = new DebtManager(auditor, IPermit2(address(0)), IBalancerVault(address(this)));
    vm.expectRevert(bytes(""));
    lev.leverage(marketUSDC, 100_000e6, 1.03e18);
  }

  function testFloatingToFixedRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrow(50_000e6, address(this), address(this));

    debtManager.rollFloatingToFixed(marketUSDC, maturity, type(uint256).max, 1e18);
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(principal, 50_000e6 + 1);
  }

  function testFloatingToFixedRollHigherThanAvailableLiquidity() external _checkBalances {
    marketUSDC.deposit(2_000_000e6, address(this));
    marketUSDC.borrow(1_000_000e6, address(this), address(this));

    debtManager.rollFloatingToFixed(marketUSDC, maturity, type(uint256).max, 1e18);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(floatingBorrowShares, 0);
    assertEq(principal, 1_000_000e6 + 2);
  }

  function testFloatingToFixedRollHigherThanAvailableLiquidityWithSlippage() external _checkBalances {
    marketUSDC.deposit(2_000_000e6, address(this));
    marketUSDC.borrow(1_000_000e6, address(this), address(this));
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    uint256 initialDebt = marketUSDC.previewRefund(floatingBorrowShares);
    uint256 fee = 1_796_320_612;

    vm.expectRevert(Disagreement.selector);
    debtManager.rollFloatingToFixed(marketUSDC, maturity, 1_000_000e6 + fee, 1e18);

    debtManager.rollFloatingToFixed(marketUSDC, maturity, 1_000_000e6 + ++fee, 1e18);
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    (, , floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertEq(principal, initialDebt + 1);
    assertEq(floatingBorrowShares, 0);
  }

  function testFloatingToFixedRollHigherThanAvailableLiquidityWithSlippageWithThreePools() external _checkBalances {
    marketUSDC.deposit(3_000_000e6, address(this));
    marketUSDC.borrow(2_000_000e6, address(this), address(this));
    vm.warp(block.timestamp + 10_000);
    uint256 fee = 3_975_653_339;

    vm.expectRevert(Disagreement.selector);
    debtManager.rollFloatingToFixed(marketUSDC, maturity, 2_000_000e6 + fee, 1e18);

    debtManager.rollFloatingToFixed(marketUSDC, maturity, 2_000_000e6 + ++fee, 1e18);
  }

  function testFixedToFloatingRollHigherThanAvailableLiquidity() external _checkBalances {
    marketUSDC.deposit(2_000_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 1_000_000e6, type(uint256).max, address(this), address(this));

    debtManager.rollFixedToFloating(marketUSDC, maturity, type(uint256).max, 1e18);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertGt(marketUSDC.previewRefund(floatingBorrowShares), 1_000_000e6);
    assertEq(principal + fee, 0);
  }

  function testFixedToFloatingRollHigherThanAvailableLiquidityWithSlippage() external _checkBalances {
    marketUSDC.deposit(2_000_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 1_000_000e6, type(uint256).max, address(this), address(this));
    uint256 fee = 261_243_388;

    vm.expectRevert(Disagreement.selector);
    debtManager.rollFixedToFloating(marketUSDC, maturity, 1_000_000e6 + fee, 1e18);

    debtManager.rollFixedToFloating(marketUSDC, maturity, 1_000_000e6 + ++fee, 1e18);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 1_000_000e6 + fee);
    assertEq(principal, 0);
  }

  function testFixedToFloatingRollHigherThanAvailableLiquidityWithSlippageWithThreeLoops() external _checkBalances {
    marketUSDC.deposit(3_000_000e6, address(this));
    vm.warp(block.timestamp + 10_000);
    marketUSDC.borrowAtMaturity(maturity, 2_000_000e6, type(uint256).max, address(this), address(this));
    uint256 fee = 650_802_165;

    vm.expectRevert(Disagreement.selector);
    debtManager.rollFixedToFloating(marketUSDC, maturity, 2_000_000e6 + fee, 1e18);

    debtManager.rollFixedToFloating(marketUSDC, maturity, 2_000_000e6 + ++fee, 1e18);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 2_000_000e6 + fee);
    assertEq(principal, 0);
  }

  function testLateFixedToFloatingRollWithThreeLoops() external _checkBalances {
    marketUSDC.deposit(3_000_000e6, address(this));
    vm.warp(block.timestamp + 10_000);
    marketUSDC.borrowAtMaturity(maturity, 2_000_000e6, type(uint256).max, address(this), address(this));
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    vm.warp(maturity + 1 days);
    uint256 debt = marketUSDC.previewDebt(address(this));
    debtManager.rollFixedToFloating(marketUSDC, maturity, type(uint256).max, 1e18);
    assertEq(debt, marketUSDC.previewDebt(address(this)) - 3);
    (uint256 newPrincipal, uint256 newFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(newPrincipal + newFee, 0);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertGt(
      marketUSDC.previewRefund(floatingBorrowShares),
      (principal + fee).mulWadDown(1 days * marketUSDC.penaltyRate())
    );
  }

  function testFloatingToFixedRollWithAccurateSlippage() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrow(50_000e6, address(this), address(this));
    uint256 maxFee = 76_622_877;

    vm.expectRevert(Disagreement.selector);
    debtManager.rollFloatingToFixed(marketUSDC, maturity, 50_000e6 + maxFee, 1e18);

    debtManager.rollFloatingToFixed(marketUSDC, maturity, 50_000e6 + ++maxFee, 1e18);
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(principal, 50_000e6 + 1);
    assertEq(fee, maxFee - 1);
  }

  function testFloatingToFixedRollWithAccurateSlippageWithPreviousPosition() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrow(50_000e6, address(this), address(this));
    marketUSDC.borrowAtMaturity(maturity, 10_000e6, type(uint256).max, address(this), address(this));
    uint256 maxFee = 76_896_076;

    vm.expectRevert(Disagreement.selector);
    debtManager.rollFloatingToFixed(marketUSDC, maturity, 50_000e6 + maxFee, 1e18);

    debtManager.rollFloatingToFixed(marketUSDC, maturity, 50_000e6 + ++maxFee, 1e18);
  }

  function testFixedToFloatingRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 10_000e6, type(uint256).max, address(this), address(this));
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    debtManager.rollFixedToFloating(marketUSDC, maturity, type(uint256).max, 1e18);
    (uint256 newPrincipal, uint256 newFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(newPrincipal + newFee, 0);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    uint256 floatingDebt = marketUSDC.previewRefund(floatingBorrowShares);
    assertGt(floatingDebt, 10_000e6);
    assertLt(floatingDebt, principal + fee);
    assertEq(usdc.balanceOf(address(debtManager)), 0);
  }

  function testPartialFixedToFloatingRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 10_000e6, type(uint256).max, address(this), address(this));
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    debtManager.rollFixedToFloating(marketUSDC, maturity, type(uint256).max, 0.5e18);
    (uint256 newPrincipal, uint256 newFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq((newPrincipal + newFee) * 2, principal + fee + 1);
  }

  function testFixedToFloatingRollWithAccurateSlippage() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 10_000e6, type(uint256).max, address(this), address(this));
    uint256 maxAssets = 10_000_460_651;

    vm.expectRevert(Disagreement.selector);
    debtManager.rollFixedToFloating(marketUSDC, maturity, maxAssets, 1e18);

    debtManager.rollFixedToFloating(marketUSDC, maturity, ++maxAssets, 1e18);
  }

  function testLateFixedToFloatingRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 10_000e6, type(uint256).max, address(this), address(this));
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    vm.warp(maturity + 1 days);
    uint256 debt = marketUSDC.previewDebt(address(this));
    debtManager.rollFixedToFloating(marketUSDC, maturity, type(uint256).max, 1e18);
    assertEq(debt, marketUSDC.previewDebt(address(this)) - 1);
    (uint256 newPrincipal, uint256 newFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(newPrincipal + newFee, 0);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertGt(
      marketUSDC.previewRefund(floatingBorrowShares),
      (principal + fee).mulWadDown(1 days * marketUSDC.penaltyRate())
    );
  }

  function testPartialLateFixedToFloatingRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 10_000e6, type(uint256).max, address(this), address(this));
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    vm.warp(maturity + 1 days);
    uint256 debt = marketUSDC.previewDebt(address(this));
    debtManager.rollFixedToFloating(marketUSDC, maturity, type(uint256).max, 0.5e18);
    assertEq(debt, marketUSDC.previewDebt(address(this)));
    (uint256 newPrincipal, uint256 newFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(newPrincipal + newFee - 1, (principal + fee) / 2);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertGt(
      marketUSDC.previewRefund(floatingBorrowShares) / 2,
      (principal + fee).mulWadDown(1 days * marketUSDC.penaltyRate()) + 1
    );
  }

  function testFixedRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));

    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, type(uint256).max, type(uint256).max, 1e18);
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(principal, 0);
    (principal, ) = marketUSDC.fixedBorrowPositions(targetMaturity, address(this));
    assertGt(principal, 50_000e6);
  }

  function testPartialFixedRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));

    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, type(uint256).max, type(uint256).max, 0.1e18);
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(principal, 45_000e6);
    (principal, ) = marketUSDC.fixedBorrowPositions(targetMaturity, address(this));
    assertGt(principal, 5_000e6);
    assertLt(principal, 5_100e6);
  }

  function testFixedRollWithAccurateRepaySlippage() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));
    uint256 maxRepayAssets = 50_002_979_931;

    vm.expectRevert(Disagreement.selector);
    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, maxRepayAssets, type(uint256).max, 1e18);

    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, ++maxRepayAssets, type(uint256).max, 1e18);
  }

  function testFixedRollWithAccurateBorrowSlippage() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));
    uint256 maxBorrowAssets = 50_206_336_876;

    vm.expectRevert(Disagreement.selector);
    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, type(uint256).max, maxBorrowAssets, 1e18);

    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, type(uint256).max, ++maxBorrowAssets, 1e18);
  }

  function testLateFixedRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));
    (uint256 repayPrincipal, uint256 repayFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    vm.warp(maturity + 1 days);
    uint256 debt = marketUSDC.previewDebt(address(this));
    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, type(uint256).max, type(uint256).max, 1e18);
    assertGt(marketUSDC.previewDebt(address(this)), debt);
    (uint256 newRepayPrincipal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(newRepayPrincipal, 0);
    (uint256 borrowPrincipal, ) = marketUSDC.fixedBorrowPositions(targetMaturity, address(this));
    assertGt(borrowPrincipal, (repayPrincipal + repayFee).mulWadDown(1 days * marketUSDC.penaltyRate()));
  }

  function testPartialLateFixedRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));
    (uint256 repayPrincipal, uint256 repayFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    vm.warp(maturity + 1 days);
    uint256 debt = marketUSDC.previewDebt(address(this));
    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, type(uint256).max, type(uint256).max, 0.5e18);
    assertGt(marketUSDC.previewDebt(address(this)), debt);
    (uint256 newRepayPrincipal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(newRepayPrincipal, 25_000e6);
    (uint256 borrowPrincipal, ) = marketUSDC.fixedBorrowPositions(targetMaturity, address(this));
    assertGt(borrowPrincipal, (repayPrincipal + repayFee).mulWadDown(1 days * marketUSDC.penaltyRate()) / 2);
  }

  function testFixedRollWithAccurateBorrowSlippageWithThreeLoops() external _checkBalances {
    marketUSDC.deposit(3_000_000e6, address(this));
    vm.warp(block.timestamp + 10_000);
    marketUSDC.borrowAtMaturity(maturity, 2_000_000e6, type(uint256).max, address(this), address(this));
    uint256 fees = 10_991_896_276;

    vm.expectRevert(Disagreement.selector);
    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, type(uint256).max, 2_000_000e6 + fees, 1e18);

    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, type(uint256).max, 2_000_000e6 + ++fees, 1e18);
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(principal + fee, 0);
    (principal, fee) = marketUSDC.fixedBorrowPositions(targetMaturity, address(this));
    assertEq(principal + fee, 2_000_000e6 + fees);
  }

  function testFixedRollSameMaturityWithThreeLoops() external _checkBalances {
    marketUSDC.deposit(3_000_000e6, address(this));
    vm.warp(block.timestamp + 10_000);
    marketUSDC.borrowAtMaturity(maturity, 2_000_000e6, type(uint256).max, address(this), address(this));

    vm.expectRevert(InvalidOperation.selector);
    debtManager.rollFixed(marketUSDC, maturity, maturity, type(uint256).max, type(uint256).max, 1e18);
  }

  function testFixedRollWithAccurateRepaySlippageWithThreeLoops() external _checkBalances {
    marketUSDC.deposit(3_000_000e6, address(this));
    vm.warp(block.timestamp + 10_000);
    marketUSDC.borrowAtMaturity(maturity, 2_000_000e6, type(uint256).max, address(this), address(this));
    uint256 maxRepayAssets = 2_000_650_802_163;

    vm.expectRevert(Disagreement.selector);
    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, maxRepayAssets, type(uint256).max, 1e18);

    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, ++maxRepayAssets, type(uint256).max, 1e18);
  }

  function testLateFixedRollWithThreeLoops() external _checkBalances {
    marketUSDC.deposit(3_000_000e6, address(this));
    vm.warp(block.timestamp + 10_000);
    marketUSDC.borrowAtMaturity(maturity, 2_000_000e6, type(uint256).max, address(this), address(this));
    (uint256 repayPrincipal, uint256 repayFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    vm.warp(maturity + 1 days);
    uint256 debt = marketUSDC.previewDebt(address(this));
    debtManager.rollFixed(marketUSDC, maturity, targetMaturity, type(uint256).max, type(uint256).max, 1e18);
    assertGt(marketUSDC.previewDebt(address(this)), debt);
    (uint256 newRepayPrincipal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(newRepayPrincipal, 0);
    (uint256 borrowPrincipal, ) = marketUSDC.fixedBorrowPositions(targetMaturity, address(this));
    assertGt(borrowPrincipal, (repayPrincipal + repayFee).mulWadDown(1 days * marketUSDC.penaltyRate()));
  }

  function testBalancerFlashloanCallFromDifferentOrigin() external {
    ERC20[] memory tokens = new ERC20[](1);
    tokens[0] = usdc;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 0;
    bytes memory maliciousCall = abi.encodeCall(
      ERC20.transferFrom,
      (address(this), address(1), usdc.balanceOf(address(this)))
    );
    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodePacked(maliciousCall);
    IBalancerVault balancerVault = debtManager.balancerVault();

    vm.expectRevert(stdError.assertionError);
    balancerVault.flashLoan(address(debtManager), tokens, amounts, abi.encode(usdc, calls));
  }

  function testMockBalancerVault() external {
    MockBalancerVault mockBalancerVault = new MockBalancerVault();
    debtManager = DebtManager(
      address(
        new ERC1967Proxy(
          address(new DebtManager(auditor, IPermit2(address(0)), IBalancerVault(address(mockBalancerVault)))),
          abi.encodeCall(DebtManager.initialize, ())
        )
      )
    );
    marketUSDC.approve(address(debtManager), type(uint256).max);
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrow(50_000e6, address(this), address(this));

    vm.expectRevert(bytes(""));
    debtManager.rollFloatingToFixed(marketUSDC, maturity, type(uint256).max, 1e18);

    deal(address(usdc), address(mockBalancerVault), 50000000001);
    debtManager.rollFloatingToFixed(marketUSDC, maturity, type(uint256).max, 1e18);
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(principal, 50_000e6 + 1);
  }

  function testPermitAndRollFloatingToFixed() external {
    marketUSDC.deposit(100_000e6, bob);
    vm.prank(bob);
    marketUSDC.borrow(50_000e6, bob, bob);

    uint256 shares = marketUSDC.previewWithdraw(50_100e6);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          marketUSDC.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              debtManager,
              shares,
              marketUSDC.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
    vm.prank(bob);
    debtManager.rollFloatingToFixed(
      marketUSDC,
      maturity,
      marketUSDC.previewRedeem(shares),
      1e18,
      Permit(bob, shares, block.timestamp, v, r, s)
    );
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, bob);
    assertEq(principal, 50_000e6 + 1);
  }

  function testPermitAndDeleverage() external {
    marketUSDC.deposit(100_000e6, bob);
    vm.prank(bob);
    marketUSDC.borrow(50_000e6, bob, bob);

    uint256 shares = marketUSDC.previewWithdraw(60_001e6);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          marketUSDC.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              debtManager,
              shares,
              marketUSDC.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
    vm.prank(bob);
    debtManager.deleverage(marketUSDC, 10_000e6, 1e18, Permit(bob, shares, block.timestamp, v, r, s));
  }

  function testPermitAndTransferLeverage() external {
    uint256 amount = 10_000e6;
    deal(address(usdc), bob, amount);

    vm.prank(bob);
    usdc.approve(address(debtManager), 10_000e6);

    uint256 shares = marketUSDC.previewWithdraw(amount);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          marketUSDC.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              debtManager,
              shares,
              marketUSDC.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
    debtManager.leverage(marketUSDC, amount, 2e18, Permit(bob, shares, block.timestamp, v, r, s));
    assertApproxEqAbs(marketUSDC.maxWithdraw(bob), amount.mulWadDown(2e18), 1);
  }

  function testAllowanceSurplus() external {
    uint256 amount = 10_000e6;
    deal(address(usdc), bob, amount);

    vm.prank(bob);
    usdc.approve(address(debtManager), 10_000e6);

    uint256 shares = marketUSDC.previewWithdraw(amount) + 101e6;
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          marketUSDC.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              debtManager,
              shares,
              marketUSDC.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
    vm.expectRevert(AllowanceSurplus.selector);
    debtManager.leverage(marketUSDC, amount, 2e18, Permit(bob, shares, block.timestamp, v, r, s));
  }

  function testPermit2AndLeverage() external {
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          permit2.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256(
                // solhint-disable-next-line max-line-length
                "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
              ),
              keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), usdc, 10_000e6)),
              debtManager,
              uint256(keccak256(abi.encode(bob, usdc, 10_000e6, block.timestamp))),
              block.timestamp
            )
          )
        )
      )
    );
    bytes memory sigAsset = abi.encodePacked(r, s, v);

    uint256 principal = 10_000e6;
    uint256 ratio = 4.1015354134e18;
    uint256 shares = marketUSDC.previewWithdraw(principal.mulWadDown(ratio - 1e18));
    (v, r, s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          marketUSDC.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              debtManager,
              shares,
              marketUSDC.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );

    vm.prank(bob);
    debtManager.leverage(
      marketUSDC,
      principal,
      ratio,
      Permit(bob, shares, block.timestamp, v, r, s),
      Permit2(block.timestamp, sigAsset)
    );

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(bob));
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(bob)), principal.mulWadDown(ratio), 1);
    assertApproxEqAbs(marketUSDC.previewRefund(floatingBorrowShares), principal.mulWadDown(ratio - 1e18), 1);
  }

  function testPermitAndLeverage() external {
    uint256 principal = 10_000e18;
    deal(address(op), bob, principal);

    (uint8 vAsset, bytes32 rAsset, bytes32 sAsset) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          op.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              debtManager,
              principal,
              op.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );

    uint256 shares = marketOP.previewWithdraw(principal.mulWadDown(0.5e18));
    (uint8 vMarket, bytes32 rMarket, bytes32 sMarket) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          marketOP.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              debtManager,
              shares,
              marketOP.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );

    vm.startPrank(bob);
    auditor.enterMarket(marketOP);
    debtManager.leverage(
      marketOP,
      1.5e18,
      Permit(bob, shares, block.timestamp, vMarket, rMarket, sMarket),
      Permit(bob, principal, block.timestamp, vAsset, rAsset, sAsset)
    );
    vm.stopPrank();

    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(bob), marketOP, 0);
    uint256 healthFactor = coll.divWadDown(debt);
    (, , uint256 floatingBorrowShares) = marketOP.accounts(address(bob));
    assertEq(healthFactor, 1.009199999999999999e18);
    assertApproxEqAbs(marketOP.maxWithdraw(address(bob)), principal.mulWadDown(1.5e18), 1);
    assertApproxEqAbs(marketOP.previewRefund(floatingBorrowShares), principal.mulWadDown(1.5e18 - 1e18), 1);
  }

  function testFakeMarketLeverage() external {
    weth.approve(address(debtManager), type(uint256).max);
    Market fakeMarketWETH = Market(address(new MockMarket(auditor, weth)));

    vm.expectRevert(MarketNotListed.selector);
    debtManager.leverage(fakeMarketWETH, 10_000e6, 4e18);
  }

  function testFakeMarketDeleverage() external {
    weth.approve(address(debtManager), type(uint256).max);
    Market fakeMarketWETH = Market(address(new MockMarket(auditor, weth)));

    vm.expectRevert(MarketNotListed.selector);
    debtManager.deleverage(fakeMarketWETH, 0, 1e18);
  }

  function testFakeMarketRollFixed() external {
    Market fakeMarketUSDC = Market(address(new MockMarket(auditor, usdc)));

    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));

    vm.expectRevert(MarketNotListed.selector);
    debtManager.rollFixed(
      fakeMarketUSDC,
      maturity,
      targetMaturity,
      type(uint256).max,
      type(uint256).max,
      1e18,
      Permit(bob, 0, 0, 0, 0, 0)
    );
  }

  function crossPrincipal(Market marketIn, Market marketOut, address sender) internal view returns (uint256) {
    (, , , , IPriceFeed priceFeedIn) = auditor.markets(marketIn);
    (, , , , IPriceFeed priceFeedOut) = auditor.markets(marketOut);
    (, , uint256 floatingBorrowShares) = marketOut.accounts(sender);

    uint256 collateral = marketIn.maxWithdraw(sender);
    uint256 debt = marketOut
      .previewRefund(floatingBorrowShares)
      .mulDivDown(auditor.assetPrice(priceFeedOut), 10 ** marketOut.decimals())
      .mulDivDown(10 ** marketIn.decimals(), auditor.assetPrice(priceFeedIn));
    return collateral - debt;
  }

  function previewAssetsOut(Market marketIn, Market marketOut, uint256 amountIn) internal view returns (uint256) {
    (, , , , IPriceFeed priceFeedIn) = auditor.markets(marketIn);
    (, , , , IPriceFeed priceFeedOut) = auditor.markets(marketOut);

    return
      amountIn.mulDivDown(auditor.assetPrice(priceFeedIn), 10 ** marketIn.decimals()).mulDivDown(
        10 ** marketOut.decimals(),
        auditor.assetPrice(priceFeedOut)
      );
  }

  modifier _checkBalances() {
    uint256 vault = usdc.balanceOf(address(debtManager.balancerVault()));
    _;
    assertLe(usdc.balanceOf(address(debtManager)), 100);
    assertEq(usdc.balanceOf(address(debtManager.balancerVault())), vault);
  }

  event Approval(address indexed owner, address indexed spender, uint256 amount);
}

enum Operation {
  FloatingToFixed,
  FixedToFloating,
  FixedToFixed
}

interface ProtocolFeesCollector {
  function setFlashLoanFeePercentage(uint256) external;
}

contract MockMarket is ERC4626 {
  Auditor public auditor;
  mapping(address => Account) public accounts;
  mapping(uint256 => mapping(address => FixedLib.Position)) public fixedBorrowPositions;
  mapping(uint256 => FixedLib.Pool) public fixedPools;

  constructor(Auditor auditor_, ERC20 asset_) ERC4626(asset_, "", "") {
    auditor = auditor_;
  }

  // solhint-disable-next-line no-empty-blocks
  function repay(uint256 assets, address borrower) external returns (uint256 actualRepay, uint256 borrowShares) {}

  // solhint-disable-next-line no-empty-blocks
  function previewRefund(uint256 shares) public view returns (uint256) {}

  // solhint-disable-next-line no-empty-blocks
  function totalAssets() public view override returns (uint256) {}

  function permit(address owner, address, uint256, uint256, uint8, bytes32, bytes32) public override {
    nonces[owner]++;
  }

  struct Account {
    uint256 fixedDeposits;
    uint256 fixedBorrows;
    uint256 floatingBorrowShares;
  }
}
