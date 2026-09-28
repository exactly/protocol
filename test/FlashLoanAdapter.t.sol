// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0; // solhint-disable-line one-contract-per-file

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ForkTest } from "./Fork.t.sol";

import { FixedLib } from "../contracts/utils/FixedLib.sol";
import { Auditor, DebtRoller, IFlashLoanRecipient, Market } from "../contracts/periphery/DebtRoller.sol";
import {
  IERC20,
  IMorpho,
  InvalidLength,
  FlashLoanAdapter,
  UnauthorizedMorpho
} from "../contracts/periphery/FlashLoanAdapter.sol";

contract FlashLoanAdapterTest is ForkTest {
  FlashLoanAdapter internal adapter;
  FlashLoanConsumer internal consumer;
  IMorpho internal morpho;
  IERC20 internal usdc;
  IERC20 internal weth;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 157_331_000);

    morpho = IMorpho(deployment("Morpho"));
    usdc = IERC20(deployment("USDC"));
    weth = IERC20(deployment("WETH"));
    adapter = new FlashLoanAdapter(morpho);
    consumer = new FlashLoanConsumer(adapter);
  }

  function test_flashLoan_lends_usdc(uint256 amount) external {
    amount = bound(amount, 1, adapter.available(usdc));
    uint256 morphoBalance = usdc.balanceOf(address(morpho));

    consumer.callFlashLoan(usdc, amount, "");

    assertLent(usdc, amount, morphoBalance);
  }

  function test_flashLoan_lends_fullBalance_usdc() external {
    uint256 amount = adapter.available(usdc);
    assertGt(amount, 0, "no usdc available");

    consumer.callFlashLoan(usdc, amount, "");

    assertLent(usdc, amount, amount);
  }

  function test_flashLoan_lends_fullBalance_weth() external {
    uint256 amount = adapter.available(weth);
    assertGt(amount, 0, "no weth available");

    consumer.callFlashLoan(weth, amount, "");

    assertLent(weth, amount, amount);
  }

  function test_flashLoan_forwardsArguments() external {
    uint256 amount = 1_000e6;
    bytes memory data = abi.encode("data");
    IERC20[] memory tokens = new IERC20[](1);
    tokens[0] = usdc;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;

    vm.expectCall(
      address(morpho),
      abi.encodeCall(IMorpho.flashLoan, (address(usdc), amount, abi.encode(address(consumer), tokens, amounts, data)))
    );
    vm.expectCall(
      address(consumer),
      abi.encodeCall(IFlashLoanRecipient.receiveFlashLoan, (tokens, amounts, new uint256[](1), data))
    );
    consumer.callFlashLoan(usdc, amount, data);
  }

  function test_flashLoan_lends_whenCallerIsNotRecipient() external {
    uint256 amount = 1_000e6;
    uint256 morphoBalance = usdc.balanceOf(address(morpho));
    IERC20[] memory tokens = new IERC20[](1);
    tokens[0] = usdc;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;

    vm.prank(makeAddr("alice"));
    adapter.flashLoan(address(consumer), tokens, amounts, "");

    assertLent(usdc, amount, morphoBalance);
  }

  function test_flashLoan_reverts_whenOverAvailable() external {
    uint256 amount = adapter.available(usdc) + 1;
    vm.expectRevert(bytes("transfer reverted"));
    consumer.callFlashLoan(usdc, amount, "");
  }

  function test_flashLoan_reverts_whenZeroAmount() external {
    vm.expectRevert(bytes("zero assets"));
    consumer.callFlashLoan(usdc, 0, "");
  }

  function test_flashLoan_reverts_whenTokensLengthNotOne() external {
    vm.expectRevert(InvalidLength.selector);
    adapter.flashLoan(address(consumer), new IERC20[](2), new uint256[](1), "");
  }

  function test_flashLoan_reverts_whenAmountsLengthNotOne() external {
    vm.expectRevert(InvalidLength.selector);
    adapter.flashLoan(address(consumer), new IERC20[](1), new uint256[](0), "");
  }

  function test_onMorphoFlashLoan_reverts_whenNotMorpho() external {
    uint256 amount = 1_000e6;
    address attacker = makeAddr("attacker");
    deal(address(usdc), address(adapter), amount);
    IERC20[] memory tokens = new IERC20[](1);
    tokens[0] = usdc;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;

    vm.prank(attacker);
    vm.expectRevert(UnauthorizedMorpho.selector);
    adapter.onMorphoFlashLoan(amount, abi.encode(attacker, tokens, amounts, ""));

    assertEq(usdc.balanceOf(address(adapter)), amount, "adapter lost tokens");
    assertEq(usdc.allowance(address(adapter), address(morpho)), 0, "allowance set");
  }

  function test_rollFixed_rolls_withDebtRoller() external {
    Auditor auditor = Auditor(deployment("Auditor"));
    upgrade(address(auditor), address(new Auditor(auditor.priceDecimals())));
    Market exaUSDC = Market(deployment("MarketUSDC"));
    DebtRoller debtRoller = DebtRoller(address(new ERC1967Proxy(address(new DebtRoller(auditor, adapter)), "")));
    debtRoller.initialize();

    address bob = makeAddr("bob");
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    uint256 borrowAmount = 1_000e6;
    deal(address(usdc), bob, 10_000e6);

    vm.startPrank(bob);
    usdc.approve(address(exaUSDC), type(uint256).max);
    exaUSDC.deposit(10_000e6, bob);
    auditor.enterMarket(exaUSDC);
    exaUSDC.borrowAtMaturity(maturity, borrowAmount, type(uint256).max, bob, bob);

    uint256 marketBalance = usdc.balanceOf(address(exaUSDC));
    uint256 morphoBalance = usdc.balanceOf(address(morpho));
    exaUSDC.approve(address(debtRoller), type(uint256).max);
    debtRoller.rollFixed(exaUSDC, maturity, maturity + FixedLib.INTERVAL, borrowAmount * 2, type(uint256).max, 1e18);
    vm.stopPrank();

    (uint256 principal, uint256 fee) = exaUSDC.fixedBorrowPositions(maturity, bob);
    assertEq(principal + fee, 0, "repay maturity not rolled");
    (principal, ) = exaUSDC.fixedBorrowPositions(maturity + FixedLib.INTERVAL, bob);
    assertGe(principal, borrowAmount, "borrow maturity not rolled");
    assertEq(usdc.balanceOf(address(exaUSDC)), marketBalance, "flash loan fee charged");
    assertEq(usdc.balanceOf(address(morpho)), morphoBalance, "morpho not repaid");
    assertEq(usdc.balanceOf(address(debtRoller)), 0, "debt roller kept tokens");
    assertEq(usdc.balanceOf(address(adapter)), 0, "adapter kept tokens");
  }

  function assertLent(IERC20 token, uint256 amount, uint256 morphoBalance) internal view {
    assertEq(consumer.received(), amount, "recipient not funded");
    assertEq(token.balanceOf(address(consumer)), 0, "recipient kept tokens");
    assertEq(token.balanceOf(address(morpho)), morphoBalance, "morpho not repaid");
    assertEq(token.balanceOf(address(adapter)), 0, "adapter kept tokens");
    assertEq(token.allowance(address(adapter), address(morpho)), 0, "allowance not consumed");
  }
}

contract FlashLoanConsumer is IFlashLoanRecipient {
  FlashLoanAdapter internal immutable adapter;
  uint256 public received;

  constructor(FlashLoanAdapter adapter_) {
    adapter = adapter_;
  }

  function callFlashLoan(IERC20 token, uint256 amount, bytes memory data) external {
    IERC20[] memory tokens = new IERC20[](1);
    tokens[0] = token;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    adapter.flashLoan(address(this), tokens, amounts, data);
  }

  function receiveFlashLoan(
    IERC20[] memory tokens,
    uint256[] memory amounts,
    uint256[] memory fees,
    bytes memory
  ) external {
    assert(msg.sender == address(adapter));
    received = tokens[0].balanceOf(address(this));
    tokens[0].transfer(address(adapter), amounts[0] + fees[0]);
  }
}
