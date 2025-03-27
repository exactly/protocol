// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Auditor, ERC20, Market, Parameters } from "../Market.sol";

contract MarketHarness is Market {
  uint256 public returnValue;

  constructor(ERC20 asset_, Auditor auditor_, Parameters memory p) Market(asset_, auditor_) {
    // solhint-disable-next-line no-inline-assembly
    assembly {
      sstore(0, 0xffff)
    }
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

  function borrowMaturityWithReturnValue(
    uint256 maturity,
    uint256 assets,
    uint256 maxAssetsAllowed,
    address receiver,
    address borrower
  ) external {
    // solhint-disable-next-line avoid-low-level-calls
    (, bytes memory data) = address(this).delegatecall(
      abi.encodeCall(this.borrowAtMaturity, (maturity, assets, maxAssetsAllowed, receiver, borrower))
    );
    returnValue = abi.decode(data, (uint256));
  }

  function depositMaturityWithReturnValue(
    uint256 maturity,
    uint256 assets,
    uint256 minAssetsRequired,
    address receiver
  ) external {
    // solhint-disable-next-line avoid-low-level-calls
    (, bytes memory data) = address(this).delegatecall(
      abi.encodeCall(this.depositAtMaturity, (maturity, assets, minAssetsRequired, receiver))
    );
    returnValue = abi.decode(data, (uint256));
  }

  function withdrawMaturityWithReturnValue(
    uint256 maturity,
    uint256 positionAssets,
    uint256 minAssetsRequired,
    address receiver,
    address owner
  ) external {
    // solhint-disable-next-line avoid-low-level-calls
    (, bytes memory data) = address(this).delegatecall(
      abi.encodeCall(this.withdrawAtMaturity, (maturity, positionAssets, minAssetsRequired, receiver, owner))
    );
    returnValue = abi.decode(data, (uint256));
  }

  function repayMaturityWithReturnValue(
    uint256 maturity,
    uint256 positionAssets,
    uint256 maxAssetsAllowed,
    address borrower
  ) external {
    // solhint-disable-next-line avoid-low-level-calls
    (, bytes memory data) = address(this).delegatecall(
      abi.encodeCall(this.repayAtMaturity, (maturity, positionAssets, maxAssetsAllowed, borrower))
    );
    returnValue = abi.decode(data, (uint256));
  }

  // function to avoid range value validation
  function setFreePenaltyRate(uint256 penaltyRate_) external {
    penaltyRate = penaltyRate_;
  }
}
