// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Script, stdJson, console2 as console } from "forge-std/Script.sol";
import { ProxyAdmin, TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

abstract contract BaseScript is Script {
  using stdJson for string;

  function upgrade(address proxy, address newImplementation) internal {
    vm.prank(deployment("ProxyAdmin"));
    TransparentUpgradeableProxy(payable(proxy)).upgradeTo(newImplementation);
  }

  function deployment(string memory name) internal returns (address addr) {
    string memory network;
    if (block.chainid == 1) network = "mainnet";
    else if (block.chainid == 5) network = "goerli";

    addr = vm.readFile(string.concat("deployments/", network, "/", name, ".json")).readAddress(".address");
    vm.label(addr, name);
  }
}
