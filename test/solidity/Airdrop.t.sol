// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ForkTest, stdError } from "./Fork.t.sol";
import { Airdrop, ISablierV2LockupLinear } from "../../contracts/periphery/Airdrop.sol";

contract AirdropTest is ForkTest {
  Airdrop internal airdrop;
  MockERC20 internal exa;
  ISablierV2LockupLinear internal sablier;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 106_835_444);
    exa = new MockERC20("EXA", "EXA", 18);
    sablier = ISablierV2LockupLinear(deployment("SablierV2LockupLinear"));
  }

  function testClaimSingleRoot() external {
    address account = 0x8967782Fb0917bab83F13Bd17db3b41C700b368D;
    uint128 amount = 420 ether;
    bytes32 root = keccak256(abi.encodePacked(account, amount));
    bytes32[] memory proof = new bytes32[](0);

    airdrop = Airdrop(
      address(new ERC1967Proxy(address(new Airdrop(exa, root, sablier)), abi.encodeCall(Airdrop.initialize, ())))
    );
    exa.mint(address(airdrop), 1_000_000 ether);

    vm.expectRevert(stdError.assertionError);
    vm.prank(account);
    airdrop.claim(amount + 1, proof);

    vm.expectRevert(stdError.assertionError);
    vm.prank(account);
    airdrop.claim(amount - 1, proof);

    vm.prank(account);
    vm.expectEmit(true, true, true, true, address(airdrop));
    emit Claim(account, 4, amount);
    uint256 streamId = airdrop.claim(amount, proof);
    assertGt(streamId, 0);
    assertEq(airdrop.streams(account), streamId);
  }

  function testClaimTwiceShouldRevert() external {
    uint128 amount = 1 ether;
    bytes32 root = keccak256(abi.encodePacked(address(this), amount));
    airdrop = Airdrop(
      address(new ERC1967Proxy(address(new Airdrop(exa, root, sablier)), abi.encodeCall(Airdrop.initialize, ())))
    );
    exa.mint(address(airdrop), 1_000_000 ether);

    airdrop.claim(1 ether, new bytes32[](0));

    vm.expectRevert(stdError.assertionError);
    airdrop.claim(1 ether, new bytes32[](0));
  }

  event Claim(address indexed account, uint256 indexed streamId, uint256 amount);
}
