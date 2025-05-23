// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17; // solhint-disable-line one-contract-per-file

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { Firewall } from "../contracts/verified/Firewall.sol";

contract FirewallTest is Test {
  Firewall internal firewall;

  function setUp() external {
    firewall = Firewall(address(new ERC1967Proxy(address(new Firewall()), "")));
    firewall.initialize();
    vm.label(address(firewall), "Firewall");
    firewall.grantRole(firewall.GRANTER_ROLE(), address(this));
  }

  // solhint-disable func-name-mixedcase

  function test_allow_allows_whenGranter() external {
    firewall.allow(address(this), true);

    (address granter, bool allowed) = firewall.allowlist(address(this));

    assertEq(granter, address(this));
    assertTrue(allowed);
  }

  function test_allow_reverts_whenNotGranter() external {
    vm.startPrank(address(0x1));
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        address(0x1),
        firewall.GRANTER_ROLE()
      )
    );
    firewall.allow(address(this), true);

    (, bool allowed) = firewall.allowlist(address(this));
    assertFalse(allowed);
  }

  function test_allow_emitsAllowlistSet() external {
    vm.expectEmit(true, true, true, true, address(firewall));
    emit AllowlistSet(address(this), address(this), true);
    firewall.allow(address(this), true);
  }

  // solhint-enable func-name-mixedcase
}

event AllowlistSet(address indexed account, address indexed granter, bool allowed);
