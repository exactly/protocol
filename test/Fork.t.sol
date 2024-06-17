// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Test, stdError, stdJson } from "forge-std/Test.sol"; // solhint-disable-line no-unused-import
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

abstract contract ForkTest is Test {
  using stdJson for string;

  function upgrade(address proxy, address newImplementation) internal {
    vm.prank(deployment("ProxyAdmin"));
    ITransparentUpgradeableProxy(payable(proxy)).upgradeTo(newImplementation);
  }

  function deployment(string memory name) internal returns (address addr) {
    addr = vm.readFile(string.concat("deployments/", chain(), "/", name, ".json")).readAddress(".address");
    vm.label(addr, name);

    address impl = address(
      uint160(uint256(vm.load(addr, bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1))))
    );
    if (impl != address(0)) vm.label(impl, string.concat(name, "_Impl"));
    else if (bytes10(addr.code) == 0x363d3d373d3d3d363d73) {
      vm.label(address(uint160(uint240(bytes30(addr.code)))), string.concat(name, "_Impl"));
    }
  }

  function chain() internal returns (string memory) {
    if (block.chainid == 1) return "ethereum";
    if (block.chainid == 11155420) return "op-sepolia";
    return getChain(block.chainid).chainAlias;
  }
}

interface IProxy {
  function implementation() external returns (address);
}
