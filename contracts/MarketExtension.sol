// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC4626, ERC20 } from "solmate/src/mixins/ERC4626.sol";

import { InterestRateModel } from "./InterestRateModel.sol";
import { MarketBase } from "./MarketBase.sol";

contract MarketExtension is MarketBase {
  constructor(ERC20 asset_) ERC4626(asset_, "", "") {
    _disableInitializers();
  }

  function initialize(
    string calldata assetSymbol,
    uint8 maxFuturePools_,
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

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setMaxFuturePools(maxFuturePools_);
    setEarningsAccumulatorSmoothFactor(earningsAccumulatorSmoothFactor_);
    setInterestRateModel(interestRateModel_);
    setPenaltyRate(penaltyRate_);
    setBackupFeeRate(backupFeeRate_);
    setReserveFactor(reserveFactor_);
    setDampSpeed(dampSpeedUp_, dampSpeedDown_);
  }
}
