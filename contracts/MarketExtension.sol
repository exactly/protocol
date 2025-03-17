// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC4626, ERC20 } from "solmate/src/mixins/ERC4626.sol";

import { InterestRateModel } from "./InterestRateModel.sol";
import { Market } from "./Market.sol";
import { MarketBase } from "./MarketBase.sol";
import { Auditor } from "./Auditor.sol";

contract MarketExtension is MarketBase {
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;

  constructor(ERC20 asset_, Auditor auditor_) ERC4626(asset_, "", "") {
    auditor = auditor_;
    _disableInitializers();
  }

  function initialize(
    string calldata assetSymbol,
    uint8 maxFuturePools_,
    uint256 maxTotalAssets_,
    uint128 earningsAccumulatorSmoothFactor_,
    InterestRateModel interestRateModel_,
    uint256 penaltyRate_,
    uint256 backupFeeRate_,
    uint128 reserveFactor_,
    uint256 floatingAssetsDampSpeedUp_,
    uint256 floatingAssetsDampSpeedDown_
  ) external initializer {
    __AccessControl_init();
    __Pausable_init();

    name = string.concat("exactly ", assetSymbol);
    symbol = string.concat("exa", assetSymbol);
    lastAccumulatorAccrual = uint32(block.timestamp);
    lastFloatingDebtUpdate = uint32(block.timestamp);
    lastAverageUpdate = uint32(block.timestamp);

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setMaxFuturePools(maxFuturePools_);
    setMaxTotalAssets(maxTotalAssets_);
    setEarningsAccumulatorSmoothFactor(earningsAccumulatorSmoothFactor_);
    setInterestRateModel(interestRateModel_);
    setPenaltyRate(penaltyRate_);
    setBackupFeeRate(backupFeeRate_);
    setReserveFactor(reserveFactor_);
    setDampSpeed(floatingAssetsDampSpeedUp_, floatingAssetsDampSpeedDown_, 0, 0);
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
}
