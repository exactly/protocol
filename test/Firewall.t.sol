// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17; // solhint-disable-line one-contract-per-file

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { AlreadyAllowed, Firewall, NotGranter } from "../contracts/verified/Firewall.sol";

contract FirewallTest is Test {
  Firewall internal firewall;
  address internal bob;

  function setUp() external {
    firewall = Firewall(address(new ERC1967Proxy(address(new Firewall()), "")));
    firewall.initialize();
    vm.label(address(firewall), "Firewall");
    firewall.grantRole(firewall.GRANTER_ROLE(), address(this));

    bob = makeAddr("bob");
  }

  // solhint-disable func-name-mixedcase

  function test_allow_allows_whenGranter() external {
    firewall.allow(address(this), true);

    (address granter, bool allowed) = firewall.allowlist(address(this));

    assertEq(granter, address(this));
    assertTrue(allowed);
  }

  function test_allow_disallows_whenGranter() external {
    firewall.allow(address(this), true);
    (address granter, bool allowed) = firewall.allowlist(address(this));
    assertEq(granter, address(this));
    assertTrue(allowed);

    firewall.allow(address(this), false);
    (granter, allowed) = firewall.allowlist(address(this));
    assertEq(granter, address(this));
    assertFalse(allowed);
  }

  function test_allow_reverts_whenNotGranter() external {
    vm.startPrank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, firewall.GRANTER_ROLE())
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

  function test_allow_reverts_whenAlreadyAllowed() external {
    firewall.allow(address(this), true);
    vm.expectRevert(abi.encodeWithSelector(AlreadyAllowed.selector, address(this)));
    firewall.allow(address(this), true);
  }

  function test_allow_reverts_whenNotOriginalGranter() external {
    address granter2 = makeAddr("granter2");
    firewall.allow(bob, true);
    firewall.grantRole(firewall.GRANTER_ROLE(), granter2);

    vm.startPrank(granter2);
    vm.expectRevert(abi.encodeWithSelector(NotGranter.selector, bob, granter2));
    firewall.allow(bob, false);
  }

  function test_allow_disallowed_allows_evenWhenNotOriginalGranter() external {
    address granter2 = makeAddr("granter2");
    firewall.grantRole(firewall.GRANTER_ROLE(), granter2);

    firewall.allow(bob, true);
    firewall.allow(bob, false);

    vm.startPrank(granter2);
    firewall.allow(bob, true);
    (address granter, bool allowed) = firewall.allowlist(bob);
    assertEq(granter, granter2);
    assertTrue(allowed);
  }

  // solhint-enable func-name-mixedcase
}

event AllowlistSet(address indexed account, address indexed granter, bool allowed);
