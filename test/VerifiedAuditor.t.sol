// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts-v5/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@openzeppelin/contracts-v5/access/IAccessControl.sol";

import { Firewall } from "../contracts/verified/Firewall.sol";
import { VerifiedAuditor, FirewallSet } from "../contracts/verified/VerifiedAuditor.sol";

contract VerifiedAuditorTest is Test {
  VerifiedAuditor internal auditor;
  Firewall internal firewall;

  function setUp() public {
    firewall = Firewall(address(new ERC1967Proxy(address(new Firewall()), "")));
    firewall.initialize();
    vm.label(address(firewall), "Firewall");
    auditor = VerifiedAuditor(address(new ERC1967Proxy(address(new VerifiedAuditor(18, firewall)), "")));
    auditor.initialize();
    vm.label(address(auditor), "Auditor");
  }

  // solhint-disable func-name-mixedcase

  function test_setFirewall_sets_whenAdmin() public {
    // Firewall newFirewall = Firewall(address(0x1));
    emit log(auditor.hasRole(auditor.DEFAULT_ADMIN_ROLE(), address(this)) ? "yes" : "no");

    // auditor.setFirewall(newFirewall);
    // assertEq(address(auditor.firewall()), address(newFirewall));
  }

  // function test_setFirewall_reverts_whenNotAdmin() public {
  //   vm.startPrank(address(0x1));
  //   vm.expectRevert(
  //     abi.encodeWithSelector(
  //       IAccessControl.AccessControlUnauthorizedAccount.selector,
  //       address(0x1),
  //       auditor.DEFAULT_ADMIN_ROLE()
  //     )
  //   );
  //   auditor.setFirewall(new Firewall());
  // }

  // function test_setFirewall_emitsFirewallSet() public {
  //   Firewall newFirewall = new Firewall();
  //   vm.expectEmit(true, true, true, true, address(auditor));
  //   emit FirewallSet(newFirewall);
  //   auditor.setFirewall(newFirewall);
  // }

  // solhint-enable func-name-mixedcase
}
