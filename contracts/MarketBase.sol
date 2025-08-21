// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

abstract contract MarketBase {
  uint8 private _initialized;
  bool private _initializing;
  uint256[50] private __gap;
  uint256[50] private ___gap;
  mapping(bytes32 => RoleData) private _roles;
  uint256[49] private ____gap;
  bool private _paused;
  uint256[49] private _____gap;

  struct RoleData {
    mapping(address => bool) members;
    bytes32 adminRole;
  }
}
