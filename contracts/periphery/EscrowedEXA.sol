// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {
  ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { EXA } from "./EXA.sol";

/// @title EscrowedEXA.
/// @notice ERC20 token that can be used to escrow EXA and vest it linearly using Sablier.
contract EscrowedEXA is ERC20VotesUpgradeable, AccessControlUpgradeable {
  using SafeERC20Upgradeable for EXA;
  using FixedPointMathLib for uint128;

  /// @notice Role that can redeem esEXA for EXA.
  bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
  /// @notice Role that can receive or transfer esEXA.
  bytes32 public constant TRANSFERRER_ROLE = keccak256("TRANSFERRER_ROLE");
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  EXA public immutable exa;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ISablierV2LockupLinear public immutable sablier;
  /// @notice Ratio of EXA to reserve when vesting, represented with 18 decimals.
  uint256 public reserveRatio;
  /// @notice Duration of vesting period.
  uint40 public vestingPeriod;
  /// @notice Mapping of streamId to reserve amount.
  mapping(uint256 => uint256) public reserves;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(EXA exa_, ISablierV2LockupLinear sablier_) {
    exa = exa_;
    sablier = sablier_;

    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize(uint40 vestingPeriod_, uint256 reserveRatio_) external initializer {
    __ERC20_init("escrowed EXA", "esEXA");
    __ERC20Permit_init("escrowed EXA");
    __ERC20Votes_init();
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    /// @dev address(0) holds the TRANSFERRER_ROLE so the token can be minted or burnt.
    _grantRole(TRANSFERRER_ROLE, address(0));

    setVestingPeriod(vestingPeriod_);
    setReserveRatio(reserveRatio_);
    exa.safeApprove(address(sablier), type(uint256).max);
  }

  /// @notice ERC20 transfer override to only allow transfers from/to TRANSFERRER_ROLE holders.
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    if (!hasRole(TRANSFERRER_ROLE, from) && !hasRole(TRANSFERRER_ROLE, to)) revert Untransferable();
    super._beforeTokenTransfer(from, to, amount);
  }

  /// @notice Mints esEXA for EXA.
  /// @param amount Amount of esEXA to mint.
  /// @param to Address to send esEXA to.
  function mint(uint256 amount, address to) external {
    assert(amount != 0);
    exa.safeTransferFrom(msg.sender, address(this), amount);
    _mint(to, amount);
  }

  /// @notice Redeems EXA for esEXA.
  /// @param amount Amount of EXA to redeem.
  /// @param to Address to send EXA to.
  /// @dev Caller must have REDEEMER_ROLE.
  function redeem(uint256 amount, address to) external onlyRole(REDEEMER_ROLE) {
    assert(amount != 0);
    _burn(msg.sender, amount);
    exa.safeTransfer(to, amount);
  }

  /// @notice Starts a vesting stream.
  /// @param amount Amount of EXA to vest.
  /// @param to Address to vest to.
  /// @param maxRatio Maximum reserve ratio accepted for the vesting.
  /// @param maxPeriod Maximum vesting period accepted for the vesting.
  /// @return streamId of the vesting stream.
  function vest(uint128 amount, address to, uint256 maxRatio, uint256 maxPeriod) public returns (uint256 streamId) {
    assert(amount != 0);
    if (reserveRatio > maxRatio || vestingPeriod > maxPeriod) revert Disagreement();

    _burn(msg.sender, amount);
    uint256 reserve = amount.mulWadUp(reserveRatio);
    exa.safeTransferFrom(msg.sender, address(this), reserve);
    streamId = sablier.createWithDurations(
      CreateWithDurations({
        asset: exa,
        sender: address(this),
        recipient: to,
        totalAmount: amount,
        cancelable: true,
        durations: Durations({ cliff: 0, total: vestingPeriod }),
        broker: Broker({ account: address(0), fee: 0 })
      })
    );
    reserves[streamId] = reserve;
    emit Vest(msg.sender, to, streamId, amount);
  }

  /// @notice Starts a vesting stream using a permit.
  /// @param amount Amount of EXA to vest.
  /// @param to Address to vest to.
  /// @param maxRatio Maximum reserve ratio accepted for the vesting.
  /// @param maxPeriod Maximum vesting period accepted for the vesting.
  /// @param p Permit for the EXA reserve.
  /// @return streamId of the vesting stream.
  function vest(
    uint128 amount,
    address to,
    uint256 maxRatio,
    uint256 maxPeriod,
    Permit calldata p
  ) external returns (uint256 streamId) {
    exa.safePermit(msg.sender, address(this), p.value, p.deadline, p.v, p.r, p.s);
    return vest(amount, to, maxRatio, maxPeriod);
  }

  /// @notice Cancels vesting streams.
  /// @param streamIds Array of streamIds to cancel.
  /// @return streamsReserves Amount of EXA in reserves that is returned to the cancelled stream holders.
  function cancel(uint256[] memory streamIds) external returns (uint256 streamsReserves) {
    uint128 refundableAmount;
    for (uint256 i = 0; i < streamIds.length; ++i) {
      uint256 streamId = streamIds[i];
      checkStream(streamId);
      assert(msg.sender == sablier.getRecipient(streamId));
      streamsReserves += reserves[streamId];
      delete reserves[streamId];
      refundableAmount += sablier.refundableAmountOf(streamId);
      withdrawMax(streamId);
      sablier.cancel(streamId);
    }
    emit Cancel(msg.sender, streamIds);
    _mint(msg.sender, refundableAmount);
    exa.safeTransfer(msg.sender, streamsReserves);
  }

  /// @notice Withdraws the EXA from the vesting streamIds. If a stream is depleted, its reserve is returned.
  /// @param streamIds Array of streamIds to withdraw from.
  function withdrawMax(uint256[] memory streamIds) public {
    for (uint256 i = 0; i < streamIds.length; ++i) {
      uint256 streamId = streamIds[i];
      checkStream(streamId);
      assert(msg.sender == sablier.getRecipient(streamId));
      withdrawMax(streamId);
    }
  }

  /// @notice Withdraws the EXA from the vesting streamId. If the stream is depleted, the reserve is returned.
  /// @param streamId streamId to withdraw from.
  function withdrawMax(uint256 streamId) internal {
    if (sablier.withdrawableAmountOf(streamId) != 0) sablier.withdrawMax(streamId, msg.sender);
    if (sablier.isDepleted(streamId)) returnReserve(streamId, msg.sender);
  }

  /// @notice Checks if a stream is valid through its reserve. Reverts with `InvalidStream` if it is not.
  /// @param streamId streamId to check.
  function checkStream(uint256 streamId) internal view {
    if (reserves[streamId] == 0) revert InvalidStream();
  }

  /// @notice Returns the reserve to the recipient.
  /// @param streamId streamId of the reserve to return.
  /// @param recipient recipient of the reserve.
  function returnReserve(uint256 streamId, address recipient) internal {
    uint256 reserve = reserves[streamId];
    delete reserves[streamId];
    exa.safeTransfer(recipient, reserve);
  }

  /// @notice Hook called when a recipient cancels a stream.
  /// @notice Mints esEXA to the recipient with the remaining EXA received from the canceled stream.
  /// @param streamId streamId of the cancelled stream.
  /// @param recipient recipient of the cancelled stream.
  /// @param senderAmount amount of EXA received back from the stream cancelling.
  function onStreamCanceled(uint256 streamId, address recipient, uint128 senderAmount, uint128) external {
    assert(msg.sender == address(sablier));
    checkStream(streamId);
    _mint(recipient, senderAmount);
    returnReserve(streamId, recipient);
  }

  /// @notice Sets the vesting period.
  /// @param vestingPeriod_ New vesting period.
  /// @dev Caller must have DEFAULT_ADMIN_ROLE.
  function setVestingPeriod(uint40 vestingPeriod_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    vestingPeriod = vestingPeriod_;
    emit VestingPeriodSet(vestingPeriod_);
  }

  /// @notice Sets the reserve ratio.
  /// @param reserveRatio_ New reserve ratio.
  /// @dev Caller must have DEFAULT_ADMIN_ROLE.
  function setReserveRatio(uint256 reserveRatio_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    assert(reserveRatio_ != 0);
    reserveRatio = reserveRatio_;
    emit ReserveRatioSet(reserveRatio_);
  }

  /// @notice Returns the current timepoint of EXA, as per ERC-6372.
  function clock() public view override returns (uint48) {
    return exa.clock();
  }

  /// @notice Returns the current clock mode of EXA, as per ERC-6372.
  // solhint-disable-next-line func-name-mixedcase
  function CLOCK_MODE() public view override returns (string memory) {
    return exa.CLOCK_MODE();
  }

  /// @notice Event emitted when the reserve ratio is set.
  event ReserveRatioSet(uint256 reserveRatio);
  /// @notice Event emitted when the vesting period is set.
  event VestingPeriodSet(uint256 vestingPeriod);
  /// @notice Event emitted when vesting streams are cancelled.
  event Cancel(address indexed account, uint256[] streamIds);
  /// @notice Event emitted when a vesting stream is created.
  event Vest(address indexed caller, address indexed account, uint256 indexed streamId, uint256 amount);
}

error Untransferable();
error InvalidStream();
error Disagreement();

/// @dev https://github.com/sablier-labs/v2-core/blob/v1.0.0/src/interfaces/ISablierV2LockupLinear.sol
interface ISablierV2LockupLinear {
  function cancel(uint256 streamId) external;

  function withdrawMax(uint256 streamId, address to) external;

  function isDepleted(uint256 streamId) external view returns (bool result);

  function getRecipient(uint256 streamId) external view returns (address recipient);

  function refundableAmountOf(uint256 streamId) external view returns (uint128 refundableAmount);

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

struct Permit {
  uint256 value;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}
