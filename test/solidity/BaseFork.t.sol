// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test, stdJson } from "forge-std/Test.sol";
import { ProxyAdmin, TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

abstract contract BaseForkTest is Test {
  using stdJson for string;

  function upgrade(address proxy, address newImplementation) internal {
    vm.prank(deployment("ProxyAdmin"));
    TransparentUpgradeableProxy(payable(proxy)).upgradeTo(newImplementation);
  }

  function upgradeAndCall(address proxy, address newImplementation, bytes memory data) internal {
    vm.prank(deployment("ProxyAdmin"));
    TransparentUpgradeableProxy(payable(proxy)).upgradeToAndCall(newImplementation, data);
  }

  function deployment(string memory name) internal returns (address addr) {
    addr = vm
      .readFile(string.concat("deployments/", getChain(block.chainid).chainAlias, "/", name, ".json"))
      .readAddress(".address");
    vm.label(addr, name);
  }
}
