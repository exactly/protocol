// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test, stdError, stdJson } from "forge-std/Test.sol";

abstract contract ForkTest is Test {
  using stdJson for string;

  function deployment(string memory name) internal returns (address addr) {
    addr = vm
      .readFile(string.concat("deployments/", getChain(block.chainid).chainAlias, "/", name, ".json"))
      .readAddress(".address");
    vm.label(addr, name);
  }
}
