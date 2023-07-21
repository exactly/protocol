// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { MerkleProofLib } from "solmate/src/utils/MerkleProofLib.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";

contract Airdrop {
  using SafeTransferLib for ERC20;
  using MerkleProofLib for bytes32[];

  ERC20 public immutable exa;
  bytes32 public immutable root;
  ISablierV2LockupLinear public immutable sablier;

  mapping(address => bool) public claimed;
  mapping(address => uint256) public streamIds;

  constructor(ERC20 exa_, bytes32 root_, ISablierV2LockupLinear sablier_) {
    exa = exa_;
    root = root_;
    sablier = sablier_;

    exa.safeApprove(address(sablier), type(uint256).max);
  }

  function claim(uint128 amount, bytes32[] calldata proof) external returns (uint256 streamId) {
    assert(!claimed[msg.sender]);
    assert(proof.verify(root, keccak256(abi.encodePacked(msg.sender, amount))));

    claimed[msg.sender] = true;
    streamIds[msg.sender] = streamId = sablier.createWithDurations(
      ISablierV2LockupLinear.CreateWithDurations({
        sender: address(this),
        recipient: msg.sender,
        totalAmount: amount,
        asset: exa,
        cancelable: false,
        durations: ISablierV2LockupLinear.Durations({ cliff: 0, total: 5 * 4 weeks }),
        broker: ISablierV2LockupLinear.Broker({ account: address(0), fee: 0 })
      })
    );
    emit Claim(msg.sender, amount, streamId);
  }

  event Claim(address indexed account, uint128 amount, uint256 streamId);
}

interface ISablierV2LockupLinear {
  struct Durations {
    uint40 cliff;
    uint40 total;
  }

  struct Broker {
    address account;
    uint256 fee;
  }

  struct CreateWithDurations {
    address sender;
    address recipient;
    uint128 totalAmount;
    ERC20 asset;
    bool cancelable;
    Durations durations;
    Broker broker;
  }

  function createWithDurations(CreateWithDurations calldata params) external returns (uint256 streamId);
}
