// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.17;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { MerkleProofLib } from "solmate/src/utils/MerkleProofLib.sol";
import { SafeTransferLib, ERC20 } from "solmate/src/utils/SafeTransferLib.sol";

contract Airdrop is Initializable {
  using MerkleProofLib for bytes32[];
  using SafeTransferLib for ERC20;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ERC20 public immutable exa;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  bytes32 public immutable root;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ISablierV2LockupLinear public immutable sablier;

  mapping(address => bool) public claimed;
  mapping(address => uint256) public streams;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(ERC20 exa_, bytes32 root_, ISablierV2LockupLinear sablier_) {
    exa = exa_;
    root = root_;
    sablier = sablier_;

    _disableInitializers();
  }

  function initialize() external initializer {
    exa.safeApprove(address(sablier), type(uint256).max);
  }

  function claim(uint128 amount, bytes32[] calldata proof) external returns (uint256 streamId) {
    assert(!claimed[msg.sender]);
    assert(proof.verify(root, keccak256(abi.encode(msg.sender, amount))));

    claimed[msg.sender] = true;
    streams[msg.sender] = streamId = sablier.createWithDurations(
      CreateWithDurations({
        asset: exa,
        sender: address(this),
        recipient: msg.sender,
        totalAmount: amount,
        cancelable: false,
        durations: Durations({ cliff: 0, total: 4 * 4 weeks }),
        broker: Broker({ account: address(0), fee: 0 })
      })
    );
    emit Claim(msg.sender, streamId, amount);
  }

  event Claim(address indexed account, uint256 indexed streamId, uint256 amount);
}

interface ISablierV2LockupLinear {
  function createWithDurations(CreateWithDurations calldata params) external returns (uint256 streamId);
}

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
