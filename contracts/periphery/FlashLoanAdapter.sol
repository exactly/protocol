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
  function flashLoan(
    address recipient,
    IERC20[] calldata tokens,
    uint256[] calldata amounts,
    bytes calldata data
  ) external {
    if (tokens.length != 1 || amounts.length != 1) revert InvalidLength();
    morpho.flashLoan(address(tokens[0]), amounts[0], abi.encode(recipient, tokens[0], data));
  }

  /// @notice Receives a flash loan from Morpho, forwards it to the recipient and approves the repayment.
  /// @param assets The amount of assets that was flash loaned.
  /// @param payload The payload containing the recipient, token, and data.
  function onMorphoFlashLoan(uint256 assets, bytes calldata payload) external {
    if (msg.sender != address(morpho)) revert UnauthorizedMorpho();
    (address recipient, IERC20 token, bytes memory data) = abi.decode(payload, (address, IERC20, bytes));
    IERC20[] memory tokens = new IERC20[](1);
    tokens[0] = token;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = assets;

    address(token).safeTransfer(recipient, assets);
    IFlashLoanRecipient(recipient).receiveFlashLoan(tokens, amounts, new uint256[](1), data);

    address(token).safeApprove(address(morpho), assets);
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
