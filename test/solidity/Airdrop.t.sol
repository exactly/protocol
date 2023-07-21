// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Vm } from "forge-std/Vm.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { Airdrop, ISablierV2LockupLinear } from "../../contracts/periphery/Airdrop.sol";
import { console2 as console } from "forge-std/console2.sol";

contract AirdropTest is Test {
  MockERC20 internal exa;
  Airdrop internal airdrop;
  ISablierV2LockupLinear internal constant sablier = ISablierV2LockupLinear(0xB923aBdCA17Aed90EB5EC5E407bd37164f632bFD);

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 106_835_444);

    exa = new MockERC20("EXA", "EXA", 18);
  }

  function testClaimSingleRoot() external {
    address account = 0x8967782Fb0917bab83F13Bd17db3b41C700b368D;
    uint128 amount = 420 ether;
    bytes32 root = keccak256(abi.encodePacked(account, amount));
    bytes32[] memory proof = new bytes32[](0);

    airdrop = new Airdrop(exa, root, sablier);
    exa.mint(address(airdrop), 1_000_000 ether);

    vm.expectRevert(stdError.assertionError);
    vm.prank(account);
    airdrop.claim(amount + 1, proof);

    vm.expectRevert(stdError.assertionError);
    vm.prank(account);
    airdrop.claim(amount - 1, proof);

    vm.prank(account);
    uint256 streamId = airdrop.claim(amount, proof);
    assertGt(streamId, 0);
    assertEq(airdrop.streamIds(account), streamId);
  }

  function testEmitClaim() external {
    uint128 amount = 1 ether;
    bytes32 root = keccak256(abi.encodePacked(address(this), amount));
    airdrop = new Airdrop(exa, root, sablier);
    exa.mint(address(airdrop), 1_000_000 ether);

    vm.expectEmit(true, true, true, false, address(airdrop));
    emit Claim(address(this), 1 ether, 4);
    airdrop.claim(1 ether, new bytes32[](0));
  }

  function testClaimTwiceShouldRevert() external {
    uint128 amount = 1 ether;
    bytes32 root = keccak256(abi.encodePacked(address(this), amount));
    airdrop = new Airdrop(exa, root, sablier);
    exa.mint(address(airdrop), 1_000_000 ether);

    airdrop.claim(1 ether, new bytes32[](0));

    vm.expectRevert(stdError.assertionError);
    airdrop.claim(1 ether, new bytes32[](0));
  }

  event Claim(address indexed account, uint128 amount, uint256 streamId);
}
