// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Math } from "@openzeppelin/contracts-v4/utils/math/Math.sol";
import { ERC4626, ERC20, SafeTransferLib } from "solmate/src/mixins/ERC4626.sol";
import { InterestRateModel } from "./InterestRateModel.sol";
import { RewardsController } from "./RewardsController.sol";
import { FixedLib } from "./utils/FixedLib.sol";
import { Auditor } from "./Auditor.sol";
import { Market } from "./Market.sol";
import { MarketBase } from "./MarketBase.sol";

contract MarketExtension is MarketBase, ERC4626 {
  using FixedPointMathLib for int256;
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;
  using SafeTransferLib for ERC20;
  using FixedLib for FixedLib.Pool;
  using FixedLib for FixedLib.Position;
  using FixedLib for uint256;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;

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

  /// @notice Flag to prevent new borrows and deposits.
  bool public isFrozen;

  /// @notice Tracks account's total amount of fixed deposits and borrows.
  mapping(address account => FixedOps consolidated) public fixedConsolidated;
  /// @notice Tracks the total amount of fixed deposits and borrows.
  FixedOps public fixedOps;
  /// @notice Flag to initialize consolidated variables per account only once.
  mapping(address account => bool initialized) public isInitialized;

  constructor(ERC20 asset_, Auditor auditor_) ERC4626(asset_, "", "") {
    auditor = auditor_;
  }

  function totalAssets() public view override returns (uint256) {
    return this.totalAssets();
  }

  function seize(Market seizeMarket, address liquidator, address borrower, uint256 assets) external {
    if (assets == 0) revert ZeroWithdraw();

    // reverts on failure
    auditor.checkSeize(seizeMarket, Market(address(this)));

    RewardsController memRewardsController = rewardsController;
    if (address(memRewardsController) != address(0)) memRewardsController.handleDeposit(borrower);

    uint256 shares = previewWithdraw(assets);
    beforeWithdraw(assets, shares);
    _burn(borrower, shares);
    emit Withdraw(msg.sender, liquidator, borrower, assets, shares);
    emit Seize(liquidator, borrower, assets);
    emit MarketUpdate(
      block.timestamp,
      totalSupply,
      floatingAssets,
      totalFloatingBorrowShares,
      floatingDebt,
      earningsAccumulator
    );

    asset.safeTransfer(liquidator, assets);
  }

  function noTransferRepayAtMaturity(
    uint256 maturity,
    uint256 positionAssets,
    uint256 maxAssets,
    address borrower,
    bool canDiscount
  ) external returns (uint256 actualRepayAssets) {
    FixedLib.Pool storage pool = fixedPools[maturity];
    FixedLib.Position memory position = fixedBorrowPositions[maturity][borrower];

    uint256 debtCovered = Math.min(positionAssets, position.principal + position.fee);

    uint256 principalCovered = FixedLib
      .Position(position.principal, position.fee)
      .scaleProportionally(debtCovered)
      .principal;

    RewardsController memRewardsController = rewardsController;
    if (address(memRewardsController) != address(0)) memRewardsController.handleBorrow(borrower);

    // early repayment allows a discount from the unassigned earnings
    if (block.timestamp < maturity) {
      // calculate the deposit fee considering the amount of debt the account'll pay
      (uint256 discountFee, uint256 backupFee) = pool.calculateDeposit(principalCovered, backupFeeRate);

      // remove the fee from unassigned earnings
      pool.unassignedEarnings -= discountFee + backupFee;
      if (canDiscount) {
        // the fee charged to the fixed pool supplier goes to the earnings accumulator
        earningsAccumulator += backupFee;

        // the fee gets discounted from the account through `actualRepayAssets`
        actualRepayAssets = debtCovered - discountFee;
      } else {
        // all fees go to the earnings accumulator
        earningsAccumulator += discountFee + backupFee;

        // there is no discount due to liquidation
        actualRepayAssets = debtCovered;
      }
    } else {
      actualRepayAssets = debtCovered + debtCovered.mulWadDown((block.timestamp - maturity) * penaltyRate);

      // all penalties go to the earnings accumulator
      earningsAccumulator += actualRepayAssets - debtCovered;
    }

    // verify that the account agrees to this discount or penalty
    if (actualRepayAssets > maxAssets) revert Disagreement();

    // reduce the borrowed from the pool and might decrease the floating backup borrowed
    floatingBackupBorrowed -= pool.repay(principalCovered);

    {
      uint256 principal = position.principal;
      // update the account position
      principalCovered = principal - position.reduceProportionally(debtCovered).principal;
    }
    fixedConsolidated[borrower].borrows -= principalCovered;
    fixedOps.borrows -= principalCovered;
    if (position.principal | position.fee == 0) {
      delete fixedBorrowPositions[maturity][borrower];
      Account storage account = accounts[borrower];
      account.fixedBorrows = account.fixedBorrows.clearMaturity(maturity);
    } else {
      // proportionally reduce the values
      fixedBorrowPositions[maturity][borrower] = position;
    }

    emit RepayAtMaturity(maturity, msg.sender, borrower, actualRepayAssets, debtCovered);
    emit FixedEarningsUpdate(block.timestamp, maturity, fixedPools[maturity].unassignedEarnings);
  }

  function clearBadDebt(address borrower) external returns (uint256 totalBadDebt) {
    Account storage account = accounts[borrower];
    uint256 accumulator = earningsAccumulator;
    uint256 packedMaturities = account.fixedBorrows;
    uint256 maturity = packedMaturities & ((1 << 32) - 1);
    packedMaturities = packedMaturities >> 32;
    while (packedMaturities != 0) {
      if (packedMaturities & 1 != 0) {
        FixedLib.Position storage position = fixedBorrowPositions[maturity][borrower];
        uint256 badDebt = position.principal + position.fee;
        if (accumulator >= badDebt) {
          RewardsController memRewardsController = rewardsController;
          if (address(memRewardsController) != address(0)) memRewardsController.handleBorrow(borrower);

          accumulator -= badDebt;
          totalBadDebt += badDebt;
          uint256 backupDebtReduction = fixedPools[maturity].repay(position.principal);

          if (backupDebtReduction != 0) {
            floatingBackupBorrowed -= backupDebtReduction;
            uint256 yield = fixedPools[maturity].unassignedEarnings.mulDivDown(
              Math.min(position.principal, backupDebtReduction),
              backupDebtReduction
            );
            fixedPools[maturity].unassignedEarnings -= yield;
            earningsAccumulator += yield;
            accumulator += yield;
          }

          uint256 principal = position.principal;
          fixedConsolidated[borrower].borrows -= principal;
          fixedOps.borrows -= principal;
          delete fixedBorrowPositions[maturity][borrower];
          account.fixedBorrows = account.fixedBorrows.clearMaturity(maturity);

          emit RepayAtMaturity(maturity, msg.sender, borrower, badDebt, badDebt);
        }
      }
      packedMaturities >>= 1;
      maturity += FixedLib.INTERVAL;
    }
  }

  function updateFloatingDebt() external returns (uint256 treasuryFee) {
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

  /// @notice Sets `isFrozen` state, triggered by an authorized account.
  function setFrozen(bool isFrozen_) external {
    if (isFrozen == isFrozen_) return;
    isFrozen = isFrozen_;
    emit Frozen(msg.sender, isFrozen_);
  }

  /// @notice Sets the rewards controller to update account rewards when operating with the Market.
  /// @param rewardsController_ new rewards controller.
  function setRewardsController(RewardsController rewardsController_) external {
    rewardsController = rewardsController_;
    emit RewardsControllerSet(rewardsController_);
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

  /// @notice Emitted when the floating debt is updated.
  /// @param timestamp current timestamp.
  /// @param utilization new floating utilization.
  event FloatingDebtUpdate(uint256 timestamp, uint256 utilization);

  /// @notice Emitted when the earnings of a maturity are updated.
  /// @param timestamp current timestamp.
  /// @param maturity maturity date where the earnings were updated.
  /// @param unassignedEarnings pending unassigned earnings.
  event FixedEarningsUpdate(uint256 timestamp, uint256 indexed maturity, uint256 unassignedEarnings);

  /// @notice Emitted when an account repays its borrows after maturity.
  /// @param maturity maturity where the account repaid its borrowed amounts.
  /// @param caller address which repaid the previously borrowed amount.
  /// @param borrower address which had the original debt.
  /// @param assets amount that was repaid.
  /// @param positionAssets amount of the debt that was covered in this repayment (penalties could have been repaid).
  event RepayAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed borrower,
    uint256 assets,
    uint256 positionAssets
  );

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

  /// @notice Emitted when an account's collateral has been seized.
  /// @param liquidator address which seized this collateral.
  /// @param borrower address which had the original debt.
  /// @param assets amount seized of the collateral.
  event Seize(address indexed liquidator, address indexed borrower, uint256 assets);

  /// @notice Emitted when `account` sets the `isFrozen` flag.
  event Frozen(address indexed account, bool isFrozen);

  /// @notice Emitted when the rewardsController is changed by admin.
  /// @param rewardsController new rewards controller to update account rewards when operating with the Market.
  event RewardsControllerSet(RewardsController indexed rewardsController);

  struct Account {
    uint256 fixedDeposits;
    uint256 fixedBorrows;
    uint256 floatingBorrowShares;
  }
  struct FixedOps {
    uint256 deposits;
    uint256 borrows;
  }
}

error Disagreement();
error ZeroWithdraw();
