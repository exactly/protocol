// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title Firewall
/// @notice Firewall contract that can be used to allow/disallow accounts from using the system.
contract Firewall is Initializable, AccessControlUpgradeable {
  bytes32 public constant ALLOWER_ROLE = keccak256("ALLOWER_ROLE");

  /// @notice Mapping to store the allowed accounts.
  mapping(address account => address allower) public allowlist;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize() external initializer {
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }

  /// @notice Allows or disallows an account.
  /// @dev Only callable by the allower role.
  /// @param account The account to allow or disallow.
  /// @param allowed Whether the account is allowed or disallowed.
  function allow(address account, bool allowed) external onlyRole(ALLOWER_ROLE) {
    address prevAllower = allowlist[account];
    if (!allowed && prevAllower != msg.sender && hasRole(ALLOWER_ROLE, prevAllower)) {
      revert NotAllower(account, msg.sender);
    }
    if (allowed && prevAllower != address(0)) revert AlreadyAllowed(account);

    if (allowed) allowlist[account] = msg.sender;
    else delete allowlist[account];

    emit Allowed(account, msg.sender, allowed);
  }

  /// @notice Returns whether an account is allowed.
  /// @param account The account to check.
  /// @return allowed Whether the account is allowed.
  function isAllowed(address account) external view returns (bool) {
    return allowlist[account] != address(0);
  }

  /// @notice Emitted when a new account is allowlisted.
  /// @param account address of the account that was allowlisted.
  /// @param allower address of the allower that allowed the account.
  /// @param allowed whether the account is allowlisted.
  event Allowed(address indexed account, address indexed allower, bool allowed);
}

error AlreadyAllowed(address account);
error NotAllower(address account, address allower);
