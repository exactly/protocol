// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

abstract contract Pausable is AccessControlUpgradeable {
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

  /// @notice Sets the pause state to true in case of emergency, triggered by an authorized account.
  /// @dev Triggers stopped state. The contract must not be paused.
  function pause() external onlyRole(PAUSER_ROLE) {
    requireNotPaused();
    paused = true;
    emit Paused(msg.sender);
  }

  /// @notice Sets the pause state to false when threat is gone, triggered by an authorized account.
  /// @dev Returns to normal state. The contract must be paused.
  function unpause() external onlyRole(PAUSER_ROLE) {
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
