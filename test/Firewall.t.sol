// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17; // solhint-disable-line one-contract-per-file

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { AlreadyAllowed, Firewall, NotAllower } from "../contracts/verified/Firewall.sol";

contract FirewallTest is Test {
  Firewall internal firewall;
  address internal bob;

  function setUp() external {
    firewall = Firewall(address(new ERC1967Proxy(address(new Firewall()), "")));
    firewall.initialize();
    vm.label(address(firewall), "Firewall");
    firewall.grantRole(firewall.ALLOWER_ROLE(), address(this));

    bob = makeAddr("bob");
  }

  // solhint-disable func-name-mixedcase

  function test_allow_allows_whenAllower() external {
    firewall.allow(address(this), true);

    assertEq(firewall.allowlist(address(this)), address(this));
  }

  function test_allow_disallows_whenAllower() external {
    firewall.allow(address(this), true);
    assertEq(firewall.allowlist(address(this)), address(this));

    firewall.allow(address(this), false);
    assertEq(firewall.allowlist(address(this)), address(0));
  }

  function test_allow_reverts_whenNotAllower() external {
    vm.startPrank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, firewall.ALLOWER_ROLE())
    );
    firewall.allow(address(this), true);

    assertEq(firewall.allowlist(address(this)), address(0));
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

  function test_allow_reverts_whenNotOriginalAllower() external {
    address allower2 = makeAddr("allower2");
    firewall.allow(bob, true);
    firewall.grantRole(firewall.ALLOWER_ROLE(), allower2);

    vm.startPrank(allower2);
    vm.expectRevert(abi.encodeWithSelector(NotAllower.selector, bob, allower2));
    firewall.allow(bob, false);
  }

  function test_allow_allows_whenDisallowedAndNotOriginalAllower() external {
    address allower2 = makeAddr("allower2");
    firewall.grantRole(firewall.ALLOWER_ROLE(), allower2);

    firewall.allow(bob, true);
    firewall.allow(bob, false);

    vm.startPrank(allower2);
    firewall.allow(bob, true);
    assertEq(firewall.allowlist(bob), allower2);
  }

  function test_disallow_disallows_whenAllowedAndOriginalAllower() external {
    firewall.allow(bob, true);
    assertTrue(firewall.isAllowed(bob));
    firewall.allow(bob, false);
    assertFalse(firewall.isAllowed(bob));
  }

  function test_disallow_reverts_whenAllowedAndNotOriginalAllower() external {
    firewall.allow(bob, true);
    address allower2 = makeAddr("allower2");
    firewall.grantRole(firewall.ALLOWER_ROLE(), allower2);
    vm.startPrank(allower2);
    vm.expectRevert(abi.encodeWithSelector(NotAllower.selector, bob, allower2));
    firewall.allow(bob, false);
  }

  function test_disallow_disallows_whenAllowedAndOriginalAllowerRoleIsRevoked() external {
    firewall.allow(bob, true);
    address allower2 = makeAddr("allower2");
    firewall.grantRole(firewall.ALLOWER_ROLE(), allower2);
    firewall.revokeRole(firewall.ALLOWER_ROLE(), address(this));

    vm.startPrank(allower2);
    firewall.allow(bob, false);
    assertFalse(firewall.isAllowed(bob));
  }

  // solhint-enable func-name-mixedcase
}

event AllowlistSet(address indexed account, address indexed allower, bool allowed);
