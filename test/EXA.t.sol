// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";
import { ProxyAdmin } from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
  ITransparentUpgradeableProxy,
  TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC7802 } from "@openzeppelin/contracts/interfaces/draft-IERC7802.sol";

import { EXA, NotProxyAdmin, ZeroAddress } from "../contracts/periphery/EXA.sol";

contract EXATest is Test {
  EXA internal exa;
  ProxyAdmin internal proxyAdmin;
  ITransparentUpgradeableProxy internal proxy;
  address internal admin;
  address internal bob;
  address internal bridge;

  function setUp() external {
    admin = makeAddr("admin");
    bob = makeAddr("bob");
    bridge = makeAddr("bridge");

    uint256 chainId = block.chainid;
    vm.chainId(10);
    proxyAdmin = new ProxyAdmin();
    exa = EXA(
      address(
        new TransparentUpgradeableProxy(address(new EXA()), address(proxyAdmin), abi.encodeCall(EXA.initialize, ()))
      )
    );
    proxy = ITransparentUpgradeableProxy(payable(address(exa)));
    proxyAdmin.upgradeAndCall(proxy, address(new EXA()), abi.encodeCall(EXA.initialize2, (admin)));
    vm.chainId(chainId);
    vm.startPrank(admin);
    exa.grantRole(exa.BRIDGE_ROLE(), bridge);
    vm.stopPrank();
  }

  function test_initialize_setsNameSymbolAndSupply() external view {
    assertEq(exa.name(), "exactly");
    assertEq(exa.symbol(), "EXA");
    assertEq(exa.totalSupply(), 10_000_000e18);
  }

  function test_initialize_totalSupplyIsZero_whenNotOptimism() external {
    EXA exa_ = EXA(
      address(
        new TransparentUpgradeableProxy(
          address(new EXA()),
          address(new ProxyAdmin()),
          abi.encodeCall(EXA.initialize, ())
        )
      )
    );
    assertEq(exa_.name(), "exactly");
    assertEq(exa_.symbol(), "EXA");
    assertEq(exa_.totalSupply(), 0);
  }

  function test_initialize2_reverts_whenCalledByNotProxyAdmin() external {
    ProxyAdmin proxyAdmin_ = new ProxyAdmin();
    EXA exa_ = EXA(
      address(
        new TransparentUpgradeableProxy(address(new EXA()), address(proxyAdmin_), abi.encodeCall(EXA.initialize, ()))
      )
    );

    vm.prank(bob);
    vm.expectRevert(NotProxyAdmin.selector);
    exa_.initialize2(admin);
  }

  function test_initialize2_reverts_whenAdminIsZeroAddress() external {
    ProxyAdmin proxyAdmin_ = new ProxyAdmin();
    ITransparentUpgradeableProxy proxy_ = ITransparentUpgradeableProxy(
      payable(
        address(
          new TransparentUpgradeableProxy(address(new EXA()), address(proxyAdmin_), abi.encodeCall(EXA.initialize, ()))
        )
      )
    );
    EXA implementation = new EXA();

    vm.expectRevert(ZeroAddress.selector);
    proxyAdmin_.upgradeAndCall(proxy_, address(implementation), abi.encodeCall(EXA.initialize2, (address(0))));
  }

  function test_initialize2_grantsAdminRole() external view {
    assertTrue(exa.hasRole(exa.DEFAULT_ADMIN_ROLE(), admin));
  }

  function test_initialize2_reverts_whenCalledTwice() external {
    EXA implementation = new EXA();

    vm.expectRevert();
    proxyAdmin.upgradeAndCall(proxy, address(implementation), abi.encodeCall(EXA.initialize2, (admin)));
  }

  function test_mint_mintsAndEmitsCrosschainMint() external {
    vm.expectEmit(true, true, true, true, address(exa));
    emit IERC7802.CrosschainMint(bob, 100e18, bridge);

    vm.prank(bridge);
    exa.mint(bob, 100e18);

    assertEq(exa.balanceOf(bob), 100e18);
  }

  function test_mint_reverts_whenCallerLacksBridgeRole() external {
    vm.expectRevert();
    exa.mint(bob, 100e18);
  }

  function test_burn_burnsAndEmitsCrosschainBurn() external {
    exa.transfer(bob, 100e18);

    vm.expectEmit(true, true, true, true, address(exa));
    emit IERC7802.CrosschainBurn(bob, 40e18, bridge);
    vm.prank(bridge);
    exa.burn(bob, 40e18);

    assertEq(exa.balanceOf(bob), 60e18);
  }

  function test_burn_reverts_whenCallerLacksBridgeRole() external {
    vm.expectRevert();
    exa.burn(bob, 100e18);
  }

  function test_crosschainMint_mintsAndEmitsCrosschainMint() external {
    vm.expectEmit(true, true, true, true, address(exa));
    emit IERC7802.CrosschainMint(bob, 100e18, bridge);

    vm.prank(bridge);
    exa.crosschainMint(bob, 100e18);

    assertEq(exa.balanceOf(bob), 100e18);
  }

  function test_crosschainMint_reverts_whenCallerLacksBridgeRole() external {
    vm.expectRevert();
    exa.crosschainMint(bob, 100e18);
  }

  function test_crosschainBurn_burnsAndEmitsCrosschainBurn() external {
    exa.transfer(bob, 100e18);

    vm.expectEmit(true, true, true, true, address(exa));
    emit IERC7802.CrosschainBurn(bob, 40e18, bridge);
    vm.prank(bridge);
    exa.crosschainBurn(bob, 40e18);

    assertEq(exa.balanceOf(bob), 60e18);
  }

  function test_crosschainBurn_reverts_whenCallerLacksBridgeRole() external {
    vm.expectRevert();
    exa.crosschainBurn(bob, 100e18);
  }

  function test_supportsInterface_returnsTrue_forIERC7802() external view {
    assertTrue(exa.supportsInterface(type(IERC7802).interfaceId));
  }

  function test_supportsInterface_returnsTrue_forIERC165() external view {
    assertTrue(exa.supportsInterface(type(IERC165).interfaceId));
  }

  function test_supportsInterface_returnsTrue_forIAccessControl() external view {
    assertTrue(exa.supportsInterface(type(IAccessControl).interfaceId));
  }

  function test_supportsInterface_returnsFalse_forInvalidInterface() external view {
    assertFalse(exa.supportsInterface(bytes4(0)));
  }
}
