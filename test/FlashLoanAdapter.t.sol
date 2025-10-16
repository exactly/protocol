// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0; // solhint-disable-line one-contract-per-file

import { IERC20 } from "@openzeppelin/contracts-v4/interfaces/IERC20.sol";

import { ForkTest } from "./Fork.t.sol";

import {
  FlashLoanAdapter,
  IBalancerVaultV3,
  IERC4626,
  IFlashLoanRecipient,
  WTokenSet
} from "../contracts/periphery/FlashLoanAdapter.sol";

contract FlashLoanAdapterTest is ForkTest {
  FlashLoanAdapter internal adapter;
  IBalancerVaultV3 internal vaultV3;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 141_227_400);

    vaultV3 = IBalancerVaultV3(0xbA1333333333a1BA1108E8412f11850A5C319bA9);
    adapter = new FlashLoanAdapter(vaultV3, address(this));
  }

  // solhint-disable func-name-mixedcase

  function test_setWToken_sets_whenAdmin() external {
    IERC20 asset = IERC20(address(0x1));
    IERC4626 wToken = IERC4626(address(0x2));

    adapter.setWToken(asset, wToken);
    assertEq(address(adapter.wTokens(asset)), address(wToken), "wToken not set");
  }

  function test_setWToken_emitsWTokenSet() external {
    IERC20 asset = IERC20(address(0x1));
    IERC4626 wToken = IERC4626(address(0x2));
    vm.expectEmit(true, true, true, true, address(adapter));
    emit WTokenSet(asset, wToken, address(this));
    adapter.setWToken(asset, wToken);
  }

  function test_setWToken_reverts_whenNotAdmin() external {
    address nonAdmin = address(0x1);
    vm.startPrank(nonAdmin);
    vm.expectRevert(bytes(""));
    adapter.setWToken(IERC20(address(0x1)), IERC4626(address(0x2)));
    assertEq(address(adapter.wTokens(IERC20(address(0x1)))), address(0), "wToken set");
  }

  function test_consumeAdapter() external {
    IERC20 rETH = IERC20(0x9Bcef72be871e61ED4fBbc7630889beE758eb81D);
    FlashLoanConsumer consumer = new FlashLoanConsumer(adapter, rETH);
    consumer.callFlashLoan();
  }

  function test_consumeAdapter_withWToken() external {
    IERC20 usdc = IERC20(deployment("USDC"));
    IERC4626 waOptUSDCn = IERC4626(address(0x41B334E9F2C0ED1f30fD7c351874a6071C53a78E));
    adapter.setWToken(usdc, waOptUSDCn);
    FlashLoanConsumer consumer = new FlashLoanConsumer(adapter, usdc);

    deal(address(usdc), address(consumer), 1);
    consumer.callFlashLoan();

    assertEq(usdc.balanceOf(address(consumer)), 0);
    assertEq(usdc.balanceOf(address(adapter)), 0);
  }

  // solhint-enable func-name-mixedcase
}

contract FlashLoanConsumer is IFlashLoanRecipient {
  FlashLoanAdapter internal adapter;
  IERC20 internal token;
  uint256 internal prevAmount;

  constructor(FlashLoanAdapter adapter_, IERC20 token_) {
    adapter = adapter_;
    token = token_;
  }

  function callFlashLoan() external {
    prevAmount = token.balanceOf(address(this));
    IERC20[] memory tokens = new IERC20[](1);
    tokens[0] = token;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 1e6;
    adapter.flashLoan(address(this), tokens, amounts, "");
  }

  function receiveFlashLoan(
    IERC20[] memory tokens,
    uint256[] memory amounts,
    uint256[] memory fees,
    bytes calldata
  ) external {
    assert(token.balanceOf(address(this)) == prevAmount + amounts[0]);
    assert(address(tokens[0]) == address(token));
    tokens[0].transfer(address(adapter), amounts[0] + fees[0]);
  }
}
