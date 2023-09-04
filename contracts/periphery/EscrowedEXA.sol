// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {
  ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { EXA } from "./EXA.sol";

contract EscrowedEXA is ERC20VotesUpgradeable, AccessControlUpgradeable {
  using SafeERC20Upgradeable for EXA;
  using FixedPointMathLib for uint128;

  bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
  bytes32 public constant TRANSFERRER_ROLE = keccak256("TRANSFERRER_ROLE");
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  EXA public immutable exa;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ISablierV2LockupLinear public immutable sablier;

  uint256 public reserveFee;

  uint40 public vestingPeriod;

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
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _grantRole(TRANSFERRER_ROLE, address(0));

    setVestingPeriod(vestingPeriod_);
    setReserveFee(reserveFee_);
    exa.safeApprove(address(sablier), type(uint256).max);
  }

  function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    if (!hasRole(TRANSFERRER_ROLE, from) && !hasRole(TRANSFERRER_ROLE, to)) revert Untransferable();
    super._afterTokenTransfer(from, to, amount);
  }

  function mint(uint256 amount) external {
    assert(amount != 0);
    exa.safeTransferFrom(msg.sender, address(this), amount);
    _mint(msg.sender, amount);
  }

  function redeem(uint256 amount) external onlyRole(REDEEMER_ROLE) {
    assert(amount != 0);
    _burn(msg.sender, amount);
    exa.safeTransfer(msg.sender, amount);
  }

  function vest(uint128 amount) external returns (uint256) {
    return vest(amount, 0, 0);
  }

  /// @notice Cancels the `streamIds` vestings and starts a new vesting of remaining EXA + `amount`
  function vest(uint128 amount, uint256[] memory streamIds) external returns (uint256) {
    uint256 balanceEXA = exa.balanceOf(address(this));
    uint256 streamsReserves = _cancel(streamIds);
    return vest(amount, uint128(exa.balanceOf(address(this)) - balanceEXA), streamsReserves);
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

  function cancel(uint256[] memory streamIds) external returns (uint256 streamsReserves) {
    uint256 balanceEXA = exa.balanceOf(address(this));
    streamsReserves = _cancel(streamIds);
    _mint(msg.sender, uint128(exa.balanceOf(address(this)) - balanceEXA));
    exa.safeTransfer(msg.sender, streamsReserves);
  }

  function _cancel(uint256[] memory streamIds) internal returns (uint256 streamsReserves) {
    for (uint256 i = 0; i < streamIds.length; ++i) {
      uint256 streamId = streamIds[i];
      assert(msg.sender == sablier.getRecipient(streamId));
      streamsReserves += reserves[streamId];
      delete reserves[streamId];
      sablier.cancel(streamId);
      withdrawMax(streamId);
    }
    emit Cancel(msg.sender, streamIds);
  }

  function withdrawMax(uint256[] memory streamIds) public {
    for (uint256 i = 0; i < streamIds.length; ++i) {
      uint256 streamId = streamIds[i];
      assert(msg.sender == sablier.getRecipient(streamId));
      withdrawMax(streamId);
    }
  }

  function withdrawMax(uint256 streamId) internal {
    if (sablier.withdrawableAmountOf(streamId) != 0) sablier.withdrawMax(streamId, msg.sender);
  }

  function setVestingPeriod(uint40 vestingPeriod_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    vestingPeriod = vestingPeriod_;
    emit VestingPeriodSet(vestingPeriod_);
  }

  function setReserveFee(uint256 reserveFee_) public onlyRole(DEFAULT_ADMIN_ROLE) {
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

  event ReserveFeeSet(uint256 reserveFee);
  event VestingPeriodSet(uint256 vestingPeriod);
  event Cancel(address indexed account, uint256[] streamIds);
  event Vest(address indexed account, uint256 indexed streamId, uint256 amount);
}

error Untransferable();

interface ISablierV2LockupLinear {
  function cancel(uint256 streamId) external;

  function withdrawMax(uint256 streamId, address to) external;

  function getRecipient(uint256 streamId) external view returns (address recipient);

  function withdrawableAmountOf(uint256 streamId) external view returns (uint128 withdrawableAmount);

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
