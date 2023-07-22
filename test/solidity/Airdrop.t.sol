// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ForkTest, stdError } from "./Fork.t.sol";
import { Airdrop, ISablierV2LockupLinear } from "../../contracts/periphery/Airdrop.sol";

contract AirdropTest is ForkTest {
  Airdrop internal airdrop;
  MockERC20 internal exa;
  bytes32[] internal proof;
  Claimable[4] internal tree;
  ISablierV2LockupLinear internal sablier;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 106_835_444);
    exa = new MockERC20("EXA", "EXA", 18);
    sablier = ISablierV2LockupLinear(deployment("SablierV2LockupLinear"));
    tree[0] = Claimable(address(this), 420 ether);
    tree[1] = Claimable(address(1), 0);
    tree[2] = Claimable(address(2), 0);
    tree[3] = Claimable(address(3), 0);
    proof.push(keccak256(abi.encode(tree[1])));
    proof.push(keccak256(abi.encode(keccak256(abi.encode(tree[2])), keccak256(abi.encode(tree[3])))));

    airdrop = Airdrop(
      address(
        new ERC1967Proxy(
          address(
            new Airdrop(
              exa,
              keccak256(abi.encode(keccak256(abi.encode(keccak256(abi.encode(tree[0])), proof[0])), proof[1])),
              sablier
            )
          ),
          abi.encodeCall(Airdrop.initialize, ())
        )
      )
    );
    exa.mint(address(airdrop), 100_000 ether);
  }

  function testClaim() external {
    vm.expectRevert(stdError.assertionError);
    airdrop.claim(tree[0].amount + 1, proof);

    vm.expectRevert(stdError.assertionError);
    airdrop.claim(tree[0].amount - 1, proof);

    vm.expectEmit(true, true, true, true, address(airdrop));
    emit Claim(address(this), 4, tree[0].amount);
    uint256 streamId = airdrop.claim(tree[0].amount, proof);
    assertGt(streamId, 0);
    assertEq(airdrop.streams(address(this)), streamId);
  }

  function testClaimTwiceShouldRevert() external {
    airdrop.claim(tree[0].amount, proof);

    vm.expectRevert(stdError.assertionError);
    airdrop.claim(tree[0].amount, proof);
  }

  function testClaimWithInvalidProofShouldRevert() external {
    bytes32[] memory invalidProof = new bytes32[](2);
    invalidProof[0] = proof[0];
    invalidProof[1] = keccak256(abi.encode(tree[0]));
    vm.expectRevert(stdError.assertionError);
    airdrop.claim(tree[0].amount, invalidProof);
  }

  event Claim(address indexed account, uint256 indexed streamId, uint256 amount);
}

struct Claimable {
  address account;
  uint128 amount;
}
