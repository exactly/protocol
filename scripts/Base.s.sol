// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Script, stdJson, console2 as console } from "forge-std/Script.sol";
import { ProxyAdmin, ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

abstract contract BaseScript is Script {
  using stdJson for string;

  function upgrade(address proxy, address newImplementation) internal {
    vm.prank(deployment("ProxyAdmin"));
    ITransparentUpgradeableProxy(payable(proxy)).upgradeTo(newImplementation);
  }

  function deployment(string memory name) internal returns (address addr) {
    addr = vm
      .readFile(string.concat("deployments/", getChain(block.chainid).chainAlias, "/", name, ".json"))
      .readAddress(".address");
    vm.label(addr, name);
  }

  // solhint-disable event-name-camelcase
  event log(string);
  event logs(bytes);
  event log_int(int);
  event log_uint(uint);
  event log_bytes(bytes);
  event log_string(string);
  event log_address(address);
  event log_bytes32(bytes32);
  event log_array(uint256[] val);
  event log_array(int256[] val);
  event log_array(address[] val);
  event log_named_address(string key, address val);
  event log_named_bytes32(string key, bytes32 val);
  event log_named_decimal_int(string key, int val, uint decimals);
  event log_named_decimal_uint(string key, uint val, uint decimals);
  event log_named_int(string key, int val);
  event log_named_uint(string key, uint val);
  event log_named_bytes(string key, bytes val);
  event log_named_string(string key, string val);
  event log_named_array(string key, uint256[] val);
  event log_named_array(string key, int256[] val);
  event log_named_array(string key, address[] val);
}
