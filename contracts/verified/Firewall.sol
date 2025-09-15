// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

contract Firewall is Initializable, AccessControlUpgradeable {
  using FixedPointMathLib for uint256;

  bytes32 public constant ALLOWER_ROLE = keccak256("ALLOWER_ROLE");

  mapping(address account => Allowed allowed) public allowlist;

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

  function allow(address account, bool allowed) external onlyRole(ALLOWER_ROLE) {
    address prevAllower = allowlist[account].allower;
    if (!allowed && prevAllower != msg.sender && hasRole(ALLOWER_ROLE, prevAllower)) {
      revert NotAllower(account, msg.sender);
    }
    if (allowed && allowlist[account].allowed) revert AlreadyAllowed(account);

    allowlist[account] = Allowed({ allower: msg.sender, allowed: allowed });
    emit AllowlistSet(account, msg.sender, allowed);
  }

  function isAllowed(address account) external view returns (bool) {
    return allowlist[account].allowed;
  }

  /// @notice Emitted when a new account is allowlisted.
  /// @param account address of the account that was allowlisted.
  /// @param allower address of the allower that allowed the account.
  /// @param allowed whether the account is allowlisted.
  event AllowlistSet(address indexed account, address indexed allower, bool allowed);
}

struct Allowed {
  address allower;
  bool allowed;
}

error AlreadyAllowed(address account);
error NotAllower(address account, address allower);
