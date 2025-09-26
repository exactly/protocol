// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC4626, ERC20, SafeTransferLib } from "solmate/src/mixins/ERC4626.sol";

import { InterestRateModel } from "./InterestRateModel.sol";
import { Market } from "./Market.sol";
import { MarketBase, IFlashLoanRecipient } from "./MarketBase.sol";
import { Auditor } from "./Auditor.sol";

contract MarketExtension is MarketBase {
  using SafeTransferLib for ERC20;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;

  constructor(ERC20 asset_, Auditor auditor_) ERC4626(asset_, "", "") {
    auditor = auditor_;
    _disableInitializers();
  }

  function initialize(
    string calldata assetSymbol,
    uint8 maxFuturePools_,
    uint256 maxSupply_,
    uint128 earningsAccumulatorSmoothFactor_,
    InterestRateModel interestRateModel_,
    uint256 penaltyRate_,
    uint256 backupFeeRate_,
    uint128 reserveFactor_,
    uint256 dampSpeedUp_,
    uint256 dampSpeedDown_
  ) external initializer {
    __AccessControl_init();
    __Pausable_init();

    name = string.concat("exactly ", assetSymbol);
    symbol = string.concat("exa", assetSymbol);
    lastAccumulatorAccrual = uint32(block.timestamp);
    lastFloatingDebtUpdate = uint32(block.timestamp);
    lastAverageUpdate = uint32(block.timestamp);
    locked = 1;

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setMaxFuturePools(maxFuturePools_);
    setMaxSupply(maxSupply_);
    setEarningsAccumulatorSmoothFactor(earningsAccumulatorSmoothFactor_);
    setInterestRateModel(interestRateModel_);
    setPenaltyRate(penaltyRate_);
    setBackupFeeRate(backupFeeRate_);
    setReserveFactor(reserveFactor_);
    setDampSpeed(dampSpeedUp_, dampSpeedDown_);
  }

  function initialize2(uint256 maxSupply_) external reinitializer(2) {
    locked = 1;
    setMaxSupply(maxSupply_);
  }

  function flashLoan(
    IFlashLoanRecipient recipient,
    uint256 amount,
    bytes calldata data
  ) external whenNotPaused nonReentrant {
    uint256 preLoanBalance = asset.balanceOf(address(this));
    asset.safeTransfer(address(recipient), amount);

    recipient.receiveFlashLoan(amount, data);

    if (asset.balanceOf(address(this)) < preLoanBalance) revert InsufficientFlashLoanRepay();
  }

  function transfer(address to, uint256 shares) public virtual override whenNotPaused returns (bool) {
    auditor.checkShortfall(Market(address(this)), msg.sender, previewRedeem(shares));
    handleRewards(false, msg.sender);
    handleRewards(false, to);
    return super.transfer(to, shares);
  }

  function transferFrom(address from, address to, uint256 shares) public virtual override whenNotPaused returns (bool) {
    auditor.checkShortfall(Market(address(this)), from, previewRedeem(shares));
    handleRewards(false, from);
    handleRewards(false, to);
    return super.transferFrom(from, to, shares);
  }

  modifier nonReentrant() {
    if (locked != 1) revert Reentrancy();
    locked = 2;
    _;
    locked = 1;
  }
}

error InsufficientFlashLoanRepay();
error Reentrancy();
