// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { IERC20, IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IFixedLender } from "./IFixedLender.sol";
import { IAuditor } from "./IAuditor.sol";

interface IEToken is IERC20, IERC20Metadata {
  /// @dev Emitted when `fixedLender` and `auditor` are set.
  /// @param fixedLender where the eToken is used.
  /// @param auditor is called in every transfer.
  event Initialized(IFixedLender indexed fixedLender, IAuditor indexed auditor);

  /// @dev Emitted when `amount` is accrued as earnings.
  event EarningsAccrued(uint256 amount);

  /// @dev Mints `amount` eTokens to `user`. Only callable by the FixedLender.
  /// @param user The address receiving the minted tokens.
  /// @param amount The amount of tokens getting minted.
  function mint(address user, uint256 amount) external;

  /// @dev Burns eTokens from `user`. Only callable by the FixedLender.
  /// @param user The owner of the eTokens, getting them burned.
  /// @param amount The amount being burned.
  function burn(address user, uint256 amount) external;

  /// @dev Increases contract earnings. Only callable by the FixedLender.
  /// @param amount The amount of underlying tokens deposited.
  function reportEarnings(uint256 amount) external;
}

error AlreadyInitialized();
error SmartPoolFundsLocked();
