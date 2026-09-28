// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts-v4/interfaces/IERC20.sol";
import { SafeTransferLib } from "solady/src/utils/SafeTransferLib.sol";

import { IFlashLoaner, IFlashLoanRecipient } from "./DebtRoller.sol";

/// @title FlashLoanAdapter
/// @notice Adapter to use Morpho flash loans with the `IFlashLoaner` interface.
///   Morpho flash loans are free, so reported fees are always zero.
contract FlashLoanAdapter is IFlashLoaner {
  using SafeTransferLib for address;

  /// @notice Morpho contract that provides the flash loans.
  IMorpho public immutable morpho;

  constructor(IMorpho morpho_) {
    morpho = morpho_;
  }

  /// @notice Performs a flash loan using Morpho.
  /// @param recipient The address to receive the flash loan.
  /// @param tokens The tokens to borrow.
  /// @param amounts The amounts to borrow.
  /// @param data Additional data to pass to the recipient.
  // solhint-disable-next-line gas-calldata-parameters
  function flashLoan(address recipient, IERC20[] memory tokens, uint256[] memory amounts, bytes memory data) external {
    if (tokens.length != 1 || amounts.length != 1) revert InvalidLength();
    morpho.flashLoan(address(tokens[0]), amounts[0], abi.encode(recipient, tokens, amounts, data));
  }

  /// @notice Receives a flash loan from Morpho, forwards it to the recipient and approves the repayment.
  /// @param payload The payload containing the recipient, tokens, amounts, and data.
  function onMorphoFlashLoan(uint256, bytes calldata payload) external {
    if (msg.sender != address(morpho)) revert UnauthorizedMorpho();
    (address recipient, IERC20[] memory tokens, uint256[] memory amounts, bytes memory data) = abi.decode(
      payload,
      (address, IERC20[], uint256[], bytes)
    );
    address token = address(tokens[0]);

    token.safeTransfer(recipient, amounts[0]);
    IFlashLoanRecipient(recipient).receiveFlashLoan(tokens, amounts, new uint256[](1), data);

    token.safeApprove(address(morpho), amounts[0]);
  }

  /// @notice Returns the amount of `token` available to be flash loaned.
  /// @param token The token to check.
  function available(IERC20 token) external view returns (uint256) {
    return token.balanceOf(address(morpho));
  }
}

interface IMorpho {
  function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

error InvalidLength();
error UnauthorizedMorpho();
