// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { EToken } from "../EToken.sol";

// mock class using EToken
contract ETokenHarness is EToken {
  constructor(
    string memory name,
    string memory symbol,
    uint8 decimals
  ) EToken(name, symbol, decimals) {} // solhint-disable-line no-empty-blocks

  function callInternalTransfer(
    address from,
    address to,
    uint256 value
  ) public {
    _transfer(from, to, value);
  }

  function callInternalApprove(
    address owner,
    address spender,
    uint256 value
  ) public {
    _approve(owner, spender, value);
  }
}
