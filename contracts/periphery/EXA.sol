// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {
  ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";

contract EXA is ERC20VotesUpgradeable {
  function initialize() external initializer {
    __ERC20_init("exactly", "EXA");
    __ERC20Permit_init("exactly");
    __ERC20Votes_init();
    _mint(msg.sender, 10_000_000e18);
  }

  function clock() public view override returns (uint48) {
    return uint48(block.timestamp);
  }

  // solhint-disable-next-line func-name-mixedcase
  function CLOCK_MODE() public pure override returns (string memory) {
    return "mode=timestamp";
  }
}
