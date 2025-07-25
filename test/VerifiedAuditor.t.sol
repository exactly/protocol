// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Firewall } from "../contracts/verified/Firewall.sol";
import { Auditor, FirewallSet, VerifiedAuditor } from "../contracts/verified/VerifiedAuditor.sol";

contract VerifiedAuditorTest is Test {
  VerifiedAuditor internal auditor;
  Firewall internal firewall;

  function setUp() public {
    firewall = Firewall(address(new ERC1967Proxy(address(new Firewall()), "")));
    firewall.initialize();
    vm.label(address(firewall), "Firewall");
    auditor = VerifiedAuditor(address(new ERC1967Proxy(address(new VerifiedAuditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18), firewall);
    vm.label(address(auditor), "VerifiedAuditor");
  }

  // solhint-disable func-name-mixedcase

  function test_setFirewall_sets_whenAdmin() public {
    Firewall newFirewall = Firewall(address(0x1));

    auditor.setFirewall(newFirewall);
    assertEq(address(auditor.firewall()), address(newFirewall));
  }

  function test_setFirewall_reverts_whenNotAdmin() public {
    Firewall newFirewall = new Firewall();
    vm.startPrank(address(0x1));
    vm.expectRevert(bytes(""));
    auditor.setFirewall(newFirewall);
  }

  function test_setFirewall_emitsFirewallSet() public {
    Firewall newFirewall = new Firewall();
    vm.expectEmit(true, true, true, true, address(auditor));
    emit FirewallSet(newFirewall);
    auditor.setFirewall(newFirewall);
  }

  // solhint-enable func-name-mixedcase
}
