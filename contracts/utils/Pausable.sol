// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

abstract contract Pausable {
  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

  bool public paused;

  /// @dev Modifier to make a function callable only when the contract is not paused.
  modifier whenNotPaused() {
    requireNotPaused();
    _;
  }

  /// @dev Throws if the contract is paused.
  function requireNotPaused() internal view {
    if (paused) revert ContractPaused();
  }

  /// @dev Triggers stopped state. The contract must not be paused.
  function _pause() internal {
    requireNotPaused();
    paused = true;
    emit Paused(msg.sender);
  }

  /// @dev Returns to normal state. The contract must be paused.
  function _unpause() internal {
    if (!paused) revert NotPaused();
    paused = false;
    emit Unpaused(msg.sender);
  }

  /// @dev Emitted when the pause is triggered by `account`.
  event Paused(address account);

  /// @dev Emitted when the pause is lifted by `account`.
  event Unpaused(address account);
}

error ContractPaused();
error NotPaused();
