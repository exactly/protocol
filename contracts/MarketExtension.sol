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

  function initialize(Parameters memory p) external initializer {
    __AccessControl_init();
    __Pausable_init();

    name = string.concat("exactly ", p.assetSymbol);
    symbol = string.concat("exa", p.assetSymbol);
    lastAccumulatorAccrual = uint32(block.timestamp);
    lastFloatingDebtUpdate = uint32(block.timestamp);
    lastAverageUpdate = uint32(block.timestamp);

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setMaxFuturePools(p.maxFuturePools);
    setMaxTotalAssets(p.maxTotalAssets);
    setEarningsAccumulatorSmoothFactor(p.earningsAccumulatorSmoothFactor);
    setInterestRateModel(p.interestRateModel);
    setPenaltyRate(p.penaltyRate);
    setBackupFeeRate(p.backupFeeRate);
    setReserveFactor(p.reserveFactor);
    setDampSpeed(p.floatingAssetsDampSpeedUp, p.floatingAssetsDampSpeedDown, p.uDampSpeedUp, p.uDampSpeedDown);
    setFixedBorrowThreshold(p.fixedBorrowThreshold, p.curveFactor, p.minThresholdFactor);
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

struct Parameters {
  string assetSymbol;
  uint8 maxFuturePools;
  uint256 maxTotalAssets;
  uint128 earningsAccumulatorSmoothFactor;
  InterestRateModel interestRateModel;
  uint256 penaltyRate;
  uint256 backupFeeRate;
  uint128 reserveFactor;
  uint256 floatingAssetsDampSpeedUp;
  uint256 floatingAssetsDampSpeedDown;
  uint256 uDampSpeedUp;
  uint256 uDampSpeedDown;
  int256 fixedBorrowThreshold;
  int256 curveFactor;
  int256 minThresholdFactor;
}
