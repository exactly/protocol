// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Firewall } from "../verified/Firewall.sol";

contract DeadAllower {
  address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
  Firewall public immutable firewall;

  constructor(Firewall firewall_) {
    firewall = firewall_;
  }

  function allow() external {
    firewall.allow(DEAD, true);
  }
}
