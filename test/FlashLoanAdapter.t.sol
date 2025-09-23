// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0; // solhint-disable-line one-contract-per-file

import { Test, stdError } from "forge-std/Test.sol";
import { FlashLoanAdapter } from "../contracts/periphery/FlashLoanAdapter.sol";

contract FlashLoanAdapterTest is Test {
  FlashLoanAdapter internal flashLoanAdapter;
  // Auditor internal auditor;
  // MockMarket internal exaUSDC;
  // MockMarket internal exaWETH;
  // MockERC20 internal usdc;
  // MockERC20 internal weth;

  function setUp() external {
    // usdc = new MockERC20("USD Coin", "USDC", 6);
    // weth = new MockERC20("WETH", "WETH", 18);
    // auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    // auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    // vm.label(address(auditor), "Auditor");
    // exaUSDC = new MockMarket(auditor, usdc);
    // vm.label(address(exaUSDC), "exaUSDC");
    // exaWETH = new MockMarket(auditor, weth);
    // vm.label(address(exaWETH), "exaWETH");
    // auditor.enableMarket(exaUSDC, new MockPriceFeed(18, 1e18), 0.8e18);
    // auditor.enableMarket(exaWETH, new MockPriceFeed(18, 1e18), 0.8e18);
    // flashLoanAdapter = new FlashLoanAdapter(auditor);
    // vm.label(address(flashLoanAdapter), "FlashLoanAdapter");
  }

  function test_flashLoan() external {}
}
