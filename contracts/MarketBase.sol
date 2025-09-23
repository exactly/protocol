// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/access/AccessControlUpgradeable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC4626, ERC20 } from "solmate/src/mixins/ERC4626.sol";

import { InterestRateModel } from "./InterestRateModel.sol";
import { RewardsController } from "./RewardsController.sol";
import { FixedLib } from "./utils/FixedLib.sol";

abstract contract MarketBase is Initializable, AccessControlUpgradeable, PausableUpgradeable, ERC4626 {
  using FixedPointMathLib for int256;
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;

  /// @notice Tracks account's fixed deposit positions by maturity, account and position.
  mapping(uint256 => mapping(address => FixedLib.Position)) public fixedDepositPositions;
  /// @notice Tracks account's fixed borrow positions by maturity, account and position.
  mapping(uint256 => mapping(address => FixedLib.Position)) public fixedBorrowPositions;
  /// @notice Tracks fixed pools state by maturity.
  mapping(uint256 => FixedLib.Pool) public fixedPools;

  /// @notice Tracks fixed deposit and borrow map and floating borrow shares of an account.
  mapping(address => Account) public accounts;

  /// @notice Amount of assets lent by the floating pool to the fixed pools.
  uint256 public floatingBackupBorrowed;
  /// @notice Amount of assets lent by the floating pool to accounts.
  uint256 public floatingDebt;

  /// @notice Accumulated earnings from extraordinary sources to be gradually distributed.
  uint256 public earningsAccumulator;
  /// @notice Rate per second to be charged to delayed fixed pools borrowers after maturity.
  uint256 public penaltyRate;
  /// @notice Rate charged to the fixed pool to be retained by the floating pool for initially providing liquidity.
  uint256 public backupFeeRate;
  /// @notice Damp speed factor to update `floatingAssetsAverage` when `floatingAssets` is higher.
  uint256 public dampSpeedUp;
  /// @notice Damp speed factor to update `floatingAssetsAverage` when `floatingAssets` is lower.
  uint256 public dampSpeedDown;

  /// @notice Number of fixed pools to be active at the same time.
  uint8 public maxFuturePools;
  /// @notice Last time the accumulator distributed earnings.
  uint32 public lastAccumulatorAccrual;
  /// @notice Last time the floating debt was updated.
  uint32 public lastFloatingDebtUpdate;
  /// @notice Last time the floating assets average was updated.
  uint32 public lastAverageUpdate;

  /// @notice Interest rate model contract used to get the borrow rates.
  InterestRateModel public interestRateModel;

  /// @notice Factor used for gradual accrual of earnings to the floating pool.
  uint128 public earningsAccumulatorSmoothFactor;
  /// @notice Percentage factor that represents the liquidity reserves that can't be borrowed.
  uint128 public reserveFactor;

  /// @notice Amount of floating assets deposited to the pool.
  uint256 public floatingAssets;
  /// @notice Average of the floating assets to get fixed borrow rates and prevent rate manipulation.
  uint256 public floatingAssetsAverage;

  /// @notice Total amount of floating borrow shares assigned to floating borrow accounts.
  uint256 public totalFloatingBorrowShares;

  /// @dev gap from deprecated state.
  /// @custom:oz-renamed-from floatingUtilization
  uint256 private __gap;

  /// @notice Address of the treasury that will receive the allocated earnings.
  address public treasury;
  /// @notice Rate to be charged by the treasury to floating and fixed borrows.
  uint256 public treasuryFeeRate;

  /// @notice Address of the rewards controller that will accrue rewards for accounts operating with the Market.
  RewardsController public rewardsController;

  /// @notice Maximum supply of shares for the market.
  uint256 public maxSupply;

  /// @notice Deposits amount of assets on behalf of the treasury address.
  /// @param fee amount of assets to be deposited.
  function depositToTreasury(uint256 fee) internal {
    if (fee != 0) {
      _mint(treasury, previewDeposit(fee));
      floatingAssets += fee;
    }
  }

  /// @notice Calculates the earnings to be distributed from the accumulator given the current timestamp.
  /// @return earnings to be distributed from the accumulator.
  function accumulatedEarnings() internal view returns (uint256 earnings) {
    uint256 elapsed = block.timestamp - lastAccumulatorAccrual;
    if (elapsed == 0) return 0;
    return
      earningsAccumulator.mulDivDown(
        elapsed,
        elapsed + earningsAccumulatorSmoothFactor.mulWadDown(maxFuturePools * FixedLib.INTERVAL)
      );
  }

  /// @notice Accrues the earnings to be distributed from the accumulator given the current timestamp.
  /// @return earnings distributed from the accumulator.
  function accrueAccumulatedEarnings() internal returns (uint256 earnings) {
    earnings = accumulatedEarnings();

    earningsAccumulator -= earnings;
    lastAccumulatorAccrual = uint32(block.timestamp);
    emit AccumulatorAccrual(block.timestamp);
  }

  /// @notice Updates the `floatingAssetsAverage`.
  function updateFloatingAssetsAverage() internal {
    floatingAssetsAverage = previewFloatingAssetsAverage();
    lastAverageUpdate = uint32(block.timestamp);
  }

  /// @notice Returns the current `floatingAssetsAverage` without updating the storage variable.
  /// @return projected `floatingAssetsAverage`.
  function previewFloatingAssetsAverage() public view returns (uint256) {
    uint256 memFloatingAssets = floatingAssets;
    uint256 memFloatingAssetsAverage = floatingAssetsAverage;
    uint256 dampSpeedFactor = memFloatingAssets < memFloatingAssetsAverage ? dampSpeedDown : dampSpeedUp;
    uint256 averageFactor = uint256(1e18 - (-int256(dampSpeedFactor * (block.timestamp - lastAverageUpdate))).expWad());
    return memFloatingAssetsAverage.mulWadDown(1e18 - averageFactor) + averageFactor.mulWadDown(memFloatingAssets);
  }

  /// @notice Updates the floating pool borrows' variables.
  /// @return treasuryFee amount of fees charged by the treasury to the new calculated floating debt.
  function updateFloatingDebt() internal returns (uint256 treasuryFee) {
    uint256 memFloatingDebt = floatingDebt;
    uint256 memFloatingAssets = floatingAssets;
    uint256 utilization = floatingUtilization(memFloatingAssets, memFloatingDebt);
    uint256 newDebt = memFloatingDebt.mulWadDown(
      interestRateModel
        .floatingRate(utilization, globalUtilization(memFloatingAssets, memFloatingDebt, floatingBackupBorrowed))
        .mulDivDown(block.timestamp - lastFloatingDebtUpdate, 365 days)
    );

    memFloatingDebt += newDebt;
    treasuryFee = newDebt.mulWadDown(treasuryFeeRate);
    floatingAssets = memFloatingAssets + newDebt - treasuryFee;
    floatingDebt = memFloatingDebt;
    lastFloatingDebtUpdate = uint32(block.timestamp);
    emit FloatingDebtUpdate(block.timestamp, utilization);
  }

  /// @notice Calculates the total floating debt, considering elapsed time since last update and current interest rate.
  /// @return actual floating debt plus projected interest.
  function totalFloatingBorrowAssets() public view returns (uint256) {
    uint256 memFloatingDebt = floatingDebt;
    uint256 memFloatingAssets = floatingAssets;
    uint256 newDebt = memFloatingDebt.mulWadDown(
      interestRateModel
        .floatingRate(
          floatingUtilization(memFloatingAssets, memFloatingDebt),
          globalUtilization(memFloatingAssets, memFloatingDebt, floatingBackupBorrowed)
        )
        .mulDivDown(block.timestamp - lastFloatingDebtUpdate, 365 days)
    );
    return memFloatingDebt + newDebt;
  }

  /// @notice Calculates the floating pool balance plus earnings to be accrued at current timestamp
  /// from maturities and accumulator.
  /// @return actual floatingAssets plus earnings to be accrued at current timestamp.
  function totalAssets() public view override returns (uint256) {
    unchecked {
      uint256 backupEarnings = 0;

      uint256 latestMaturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL);
      uint256 maxMaturity = latestMaturity + maxFuturePools * FixedLib.INTERVAL;

      for (uint256 maturity = latestMaturity; maturity <= maxMaturity; maturity += FixedLib.INTERVAL) {
        FixedLib.Pool storage pool = fixedPools[maturity];
        uint256 lastAccrual = pool.lastAccrual;

        if (maturity > lastAccrual) {
          backupEarnings += block.timestamp < maturity
            ? pool.unassignedEarnings.mulDivDown(block.timestamp - lastAccrual, maturity - lastAccrual)
            : pool.unassignedEarnings;
        }
      }

      return
        floatingAssets +
        backupEarnings +
        accumulatedEarnings() +
        (totalFloatingBorrowAssets() - floatingDebt).mulWadDown(1e18 - treasuryFeeRate);
    }
  }

  /// @notice Retrieves global utilization of the floating pool.
  /// @dev Internal function to avoid code duplication.
  function globalUtilization(uint256 assets, uint256 debt, uint256 backupBorrowed) internal pure returns (uint256) {
    return assets != 0 ? (debt + backupBorrowed).divWadUp(assets) : 0;
  }

  /// @notice Retrieves floating utilization of the floating pool.
  /// @dev Internal function to avoid code duplication.
  function floatingUtilization(uint256 assets, uint256 debt) internal pure returns (uint256) {
    return assets != 0 ? debt.divWadUp(assets) : 0;
  }

  /// @notice Triggers rewards' updates in rewards controller.
  /// @dev Internal function to avoid code duplication.
  function handleRewards(bool isBorrow, address account) internal virtual {
    RewardsController memRewardsController = rewardsController;
    if (address(memRewardsController) != address(0)) {
      if (isBorrow) memRewardsController.handleBorrow(account);
      else memRewardsController.handleDeposit(account);
    }
  }

  /// @notice Emits MarketUpdate event.
  /// @dev Internal function to avoid code duplication.
  function emitMarketUpdate() internal {
    emit MarketUpdate(
      block.timestamp,
      totalSupply,
      floatingAssets,
      totalFloatingBorrowShares,
      floatingDebt,
      earningsAccumulator
    );
  }

  /// @notice Sets the rate charged to the fixed depositors that the floating pool suppliers will retain for initially
  /// providing liquidity.
  /// @param backupFeeRate_ percentage amount represented with 18 decimals.
  function setBackupFeeRate(uint256 backupFeeRate_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    backupFeeRate = backupFeeRate_;
    emit BackupFeeRateSet(backupFeeRate_);
  }

  /// @notice Sets the damp speed used to update the floatingAssetsAverage.
  /// @param up damp speed up, represented with 18 decimals.
  /// @param down damp speed down, represented with 18 decimals.
  function setDampSpeed(uint256 up, uint256 down) public onlyRole(DEFAULT_ADMIN_ROLE) {
    updateFloatingAssetsAverage();
    dampSpeedUp = up;
    dampSpeedDown = down;
    emit DampSpeedSet(up, down);
  }

  /// @notice Sets the factor used when smoothly accruing earnings to the floating pool.
  /// @param earningsAccumulatorSmoothFactor_ represented with 18 decimals.
  function setEarningsAccumulatorSmoothFactor(
    uint128 earningsAccumulatorSmoothFactor_
  ) public onlyRole(DEFAULT_ADMIN_ROLE) {
    floatingAssets += accrueAccumulatedEarnings();
    emitMarketUpdate();
    earningsAccumulatorSmoothFactor = earningsAccumulatorSmoothFactor_;
    emit EarningsAccumulatorSmoothFactorSet(earningsAccumulatorSmoothFactor_);
  }

  /// @notice Sets the interest rate model to be used to calculate rates.
  /// @param interestRateModel_ new interest rate model.
  function setInterestRateModel(InterestRateModel interestRateModel_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (address(interestRateModel) != address(0)) depositToTreasury(updateFloatingDebt());

    interestRateModel = interestRateModel_;
    emitMarketUpdate();
    emit InterestRateModelSet(interestRateModel_);
  }

  /// @notice Sets the protocol's max future pools for fixed borrowing and lending.
  /// @dev If value is decreased, VALID maturities will become NOT_READY.
  /// @param futurePools number of pools to be active at the same time.
  function setMaxFuturePools(uint8 futurePools) public onlyRole(DEFAULT_ADMIN_ROLE) {
    maxFuturePools = futurePools;
    emit MaxFuturePoolsSet(futurePools);
  }

  /// @notice Sets the maximum supply of shares for the market.
  /// @param maxSupply_ maximum supply of shares for the market.
  function setMaxSupply(uint256 maxSupply_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    maxSupply = maxSupply_;
    emit MaxSupplySet(maxSupply_);
  }

  /// @notice Sets the penalty rate per second.
  /// @param penaltyRate_ percentage represented with 18 decimals.
  function setPenaltyRate(uint256 penaltyRate_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    penaltyRate = penaltyRate_;
    emit PenaltyRateSet(penaltyRate_);
  }

  /// @notice Sets the percentage that represents the liquidity reserves that can't be borrowed.
  /// @param reserveFactor_ parameter represented with 18 decimals.
  function setReserveFactor(uint128 reserveFactor_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    reserveFactor = reserveFactor_;
    emit ReserveFactorSet(reserveFactor_);
  }

  /// @notice Emitted when the backupFeeRate parameter is changed by admin.
  /// @param backupFeeRate rate charged to the fixed pools to be accrued by the floating depositors.
  event BackupFeeRateSet(uint256 backupFeeRate);

  /// @notice Emitted when the damp speeds are changed by admin.
  /// @param dampSpeedUp represented with 18 decimals.
  /// @param dampSpeedDown represented with 18 decimals.
  event DampSpeedSet(uint256 dampSpeedUp, uint256 dampSpeedDown);

  /// @notice Emitted when the earningsAccumulatorSmoothFactor is changed by admin.
  /// @param earningsAccumulatorSmoothFactor factor represented with 18 decimals.
  event EarningsAccumulatorSmoothFactorSet(uint256 earningsAccumulatorSmoothFactor);

  /// @notice Emitted when the interestRateModel is changed by admin.
  /// @param interestRateModel new interest rate model to be used to calculate rates.
  event InterestRateModelSet(InterestRateModel indexed interestRateModel);

  /// @notice Emitted when the maxFuturePools is changed by admin.
  /// @param maxFuturePools represented with 0 decimals.
  event MaxFuturePoolsSet(uint256 maxFuturePools);

  /// @notice Emitted when the maxSupply is changed by admin.
  /// @param maxSupply maximum supply of shares for the market.
  event MaxSupplySet(uint256 maxSupply);

  /// @notice Emitted when the penaltyRate is changed by admin.
  /// @param penaltyRate penaltyRate percentage per second represented with 18 decimals.
  event PenaltyRateSet(uint256 penaltyRate);

  /// @notice Emitted when the reserveFactor is changed by admin.
  /// @param reserveFactor reserveFactor percentage.
  event ReserveFactorSet(uint256 reserveFactor);

  /// @notice Emitted when market state is updated.
  /// @param timestamp current timestamp.
  /// @param floatingDepositShares total floating supply shares.
  /// @param floatingAssets total floating supply assets.
  /// @param floatingBorrowShares total floating borrow shares.
  /// @param floatingDebt total floating borrow assets.
  /// @param earningsAccumulator earnings accumulator.
  event MarketUpdate(
    uint256 timestamp,
    uint256 floatingDepositShares,
    uint256 floatingAssets,
    uint256 floatingBorrowShares,
    uint256 floatingDebt,
    uint256 earningsAccumulator
  );

  /// @notice Emitted when accumulator distributes earnings.
  /// @param timestamp current timestamp.
  event AccumulatorAccrual(uint256 timestamp);

  /// @notice Emitted when the floating debt is updated.
  /// @param timestamp current timestamp.
  /// @param utilization new floating utilization.
  event FloatingDebtUpdate(uint256 timestamp, uint256 utilization);

  /// @notice Stores fixed deposits and fixed borrows map and floating borrow shares of an account.
  /// @param fixedDeposits encoded map maturity dates where the account supplied to.
  /// @param fixedBorrows encoded map maturity dates where the account borrowed from.
  /// @param floatingBorrowShares number of floating borrow shares assigned to the account.
  struct Account {
    uint256 fixedDeposits;
    uint256 fixedBorrows;
    uint256 floatingBorrowShares;
  }
}

interface IFlashLoanRecipient {
  function receiveFlashLoan(uint256 amount, bytes memory data) external;
}
