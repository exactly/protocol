// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {
  ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { EXA } from "./EXA.sol";

contract EscrowedEXA is ERC20VotesUpgradeable, OwnableUpgradeable {
  using SafeERC20Upgradeable for EXA;
  using FixedPointMathLib for uint128;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  EXA public immutable exa;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ISablierV2LockupLinear public immutable sablier;

  uint256 public reserveFee;

  uint40 public vestingPeriod;

  mapping(address => bool) public allowlist;
  /// @dev reserves[streamId] = amount
  mapping(uint256 => uint256) public reserves;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(EXA exa_, ISablierV2LockupLinear sablier_) {
    exa = exa_;
    sablier = sablier_;

    _disableInitializers();
  }

  function initialize(uint40 vestingPeriod_, uint256 reserveFee_) external initializer {
    __ERC20_init("escrowed EXA", "esEXA");
    __ERC20Permit_init("escrowed EXA");
    __ERC20Votes_init();
    __Ownable_init();

    setVestingPeriod(vestingPeriod_);
    setReserveFee(reserveFee_);
    exa.safeApprove(address(sablier), type(uint256).max);
    allowTransfer(address(0), true);
  }

  function mint(uint256 amount) external {
    assert(amount != 0);
    exa.safeTransferFrom(msg.sender, address(this), amount);
    _mint(msg.sender, amount);
  }

  /// @notice Cancels the `streamIds` vestings and starts a new vesting of remaining EXA + `amount`
  function vest(uint128 amount, uint256[] memory streamIds) external returns (uint256) {
    uint256 balanceEXA = exa.balanceOf(address(this));
    uint256 streamsReserves;
    for (uint256 i = 0; i < streamIds.length; ++i) {
      uint256 streamId = streamIds[i];
      assert(msg.sender == sablier.getRecipient(streamId));
      sablier.cancel(streamId);
      streamsReserves += reserves[streamId];
    }
    return vest(amount, uint128(exa.balanceOf(address(this)) - balanceEXA), streamsReserves);
  }

  function vest(uint128 amount) external returns (uint256) {
    return vest(amount, 0, 0);
  }

  function vest(uint128 amount, uint128 legacyAmount, uint256 legacyReserve) internal returns (uint256 streamId) {
    _burn(msg.sender, amount);

    uint128 totalAmount = amount + legacyAmount;
    uint256 fee = totalAmount.mulWadDown(reserveFee);

    if (fee > legacyReserve) exa.safeTransferFrom(msg.sender, address(this), fee - legacyReserve);
    else exa.safeTransfer(msg.sender, legacyReserve - fee);

    streamId = sablier.createWithDurations(
      CreateWithDurations({
        asset: exa,
        sender: address(this),
        recipient: msg.sender,
        totalAmount: totalAmount,
        cancelable: true,
        durations: Durations({ cliff: 0, total: vestingPeriod }),
        broker: Broker({ account: address(0), fee: 0 })
      })
    );
    reserves[streamId] = fee;
    emit Vest(msg.sender, streamId, amount);
  }

  function setVestingPeriod(uint40 vestingPeriod_) public onlyOwner {
    vestingPeriod = vestingPeriod_;
    emit VestingPeriodSet(vestingPeriod_);
  }

  function allowTransfer(address account, bool allow) public onlyOwner {
    allowlist[account] = allow;
    emit TransferAllowed(account, allow);
  }

  function setReserveFee(uint256 reserveFee_) public onlyOwner {
    reserveFee = reserveFee_;
    emit ReserveFeeSet(reserveFee_);
  }

  function clock() public view override returns (uint48) {
    return exa.clock();
  }

  // solhint-disable-next-line func-name-mixedcase
  function CLOCK_MODE() public view override returns (string memory) {
    return exa.CLOCK_MODE();
  }

  function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    assert(allowlist[from] || allowlist[to]);
    super._afterTokenTransfer(from, to, amount);
  }

  event ReserveFeeSet(uint256 reserveFee);
  event VestingPeriodSet(uint256 vestingPeriod);
  event TransferAllowed(address indexed account, bool allow);
  event Vest(address indexed account, uint256 indexed streamId, uint256 amount);
}

interface ISablierV2LockupLinear {
  function cancel(uint256 streamId) external;

  function getRecipient(uint256 streamId) external view returns (address recipient);

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
  EXA asset;
  bool cancelable;
  Durations durations;
  Broker broker;
}
