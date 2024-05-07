// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EscrowedEXA } from "../contracts/periphery/EscrowedEXA.sol";
import { BaseScript } from "./Base.s.sol";

contract CoinstoreExtraScript is BaseScript {
  address public constant TREASURY = 0x23fD464e0b0eE21cEdEb929B19CABF9bD5215019;
  address public constant DEPLOYER = 0xe61Bdef3FFF4C3CF7A07996DCB8802b5C85B665a;
  address public constant MULTISIG = 0xC0d6Bc5d052d1e74523AD79dD5A954276c9286D3;
  address public constant EXTRA = 0x89F0885DA2553232aeEf201692F8C97E24715c83;

  function run() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 119_751_100);
    address exa = deployment("EXA");
    address esEXA = deployment("esEXA");
    TimelockController timelock = TimelockController(payable(deployment("TimelockController")));

    bytes32 salt = keccak256("may7");

    vm.startBroadcast(DEPLOYER);
    timelock.schedule(exa, 0, abi.encodeCall(IERC20.transfer, (TREASURY, 39_000e18)), 0, salt, 24 hours);
    timelock.schedule(exa, 0, abi.encodeCall(IERC20.approve, (esEXA, 1_000e18)), 0, salt, 24 hours);
    timelock.schedule(esEXA, 0, abi.encodeCall(EscrowedEXA.mint, (1_000e18, EXTRA)), 0, salt, 24 hours);
    vm.stopBroadcast();

    if (vm.envOr("SCRIPT_SIMULATE", false)) {
      vm.warp(block.timestamp + 24 hours);
      uint256 timelockBalance = IERC20(exa).balanceOf(address(timelock));

      vm.startBroadcast(MULTISIG);
      timelock.execute(exa, 0, abi.encodeCall(IERC20.transfer, (TREASURY, 39_000e18)), 0, salt);
      timelock.execute(exa, 0, abi.encodeCall(IERC20.approve, (esEXA, 1_000e18)), 0, salt);
      timelock.execute(esEXA, 0, abi.encodeCall(EscrowedEXA.mint, (1_000e18, EXTRA)), 0, salt);
      vm.stopBroadcast();

      assert(IERC20(exa).balanceOf(address(timelock)) == timelockBalance - 40_000e18);
    }
  }
}
