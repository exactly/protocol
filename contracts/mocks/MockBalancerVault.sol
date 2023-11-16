// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { ReentrancyGuard } from "solmate/src/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";

contract MockBalancerVault is ReentrancyGuard {
  using SafeTransferLib for ERC20;

  function flashLoan(
    IFlashLoanRecipient recipient,
    ERC20[] memory tokens,
    uint256[] memory amounts,
    bytes memory userData
  ) external nonReentrant {
    assert(tokens.length == amounts.length);

    uint256[] memory preLoanBalances = new uint256[](tokens.length);

    // Used to ensure `tokens` is sorted in ascending order, which ensures token uniqueness.
    ERC20 previousToken = ERC20(address(0));

    for (uint256 i = 0; i < tokens.length; ++i) {
      ERC20 token = tokens[i];
      uint256 amount = amounts[i];

      require(token > previousToken, token == ERC20(address(0)) ? "Zero token" : "Unsorted tokens");
      previousToken = token;

      preLoanBalances[i] = token.balanceOf(address(this));

      require(preLoanBalances[i] >= amount, "Insufficient flashloan balance");
      token.safeTransfer(address(recipient), amount);
    }

    recipient.receiveFlashLoan(tokens, amounts, new uint256[](tokens.length), userData);

    for (uint256 i = 0; i < tokens.length; ++i) {
      uint256 postLoanBalance = tokens[i].balanceOf(address(this));
      require(postLoanBalance >= preLoanBalances[i], "Invalid post flashloan balance");
    }
  }
}

interface IFlashLoanRecipient {
  function receiveFlashLoan(
    ERC20[] memory tokens,
    uint256[] memory amounts,
    uint256[] memory feeAmounts,
    bytes memory userData
  ) external;
}
