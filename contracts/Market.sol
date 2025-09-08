// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable-v4/utils/math/MathUpgradeable.sol";
import { ERC4626, ERC20, SafeTransferLib } from "solmate/src/mixins/ERC4626.sol";
import { RewardsController } from "./RewardsController.sol";
import { MarketExtension, Parameters } from "./MarketExtension.sol";
import { MarketBase } from "./MarketBase.sol";
import { FixedLib } from "./utils/FixedLib.sol";
import { Auditor } from "./Auditor.sol";

contract Market is MarketBase {
  using FixedPointMathLib for int256;
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;
  using SafeTransferLib for ERC20;
  using FixedLib for FixedLib.Pool;
  using FixedLib for FixedLib.Position;
  using FixedLib for uint256;

  bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  bytes32 private constant EMERGENCY_ADMIN_ROLE = keccak256("EMERGENCY_ADMIN_ROLE");

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  MarketExtension public immutable extension;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(ERC20 asset_, Auditor auditor_) ERC4626(asset_, "", "") {
    auditor = auditor_;
    extension = new MarketExtension(asset_, auditor_);

    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize(
    // solhint-disable no-unused-vars
    Parameters memory p
  ) external {
    // solhint-enable no-unused-vars
    delegateToExtension();
  }

  /// @notice Borrows a certain amount from the floating pool.
  /// @param assets amount to be sent to receiver and repaid by borrower.
  /// @param receiver address that will receive the borrowed assets.
  /// @param borrower address that will repay the borrowed assets.
  /// @return borrowShares shares corresponding to the borrowed assets.
  function borrow(
    uint256 assets,
    address receiver,
    address borrower
  ) external whenNotPaused whenNotFrozen returns (uint256 borrowShares) {
    if (assets == 0) revert ZeroBorrow();
    spendAllowance(borrower, assets);

    handleRewards(true, borrower);

    depositToTreasury(updateFloatingDebt());

    borrowShares = previewBorrow(assets);

    uint256 newFloatingDebt = floatingDebt + assets;
    floatingDebt = newFloatingDebt;
    // check if the underlying liquidity that the account wants to withdraw is borrowed, also considering the reserves
    if (floatingBackupBorrowed + newFloatingDebt > floatingAssets.mulWadDown(1e18 - reserveFactor)) {
      revert InsufficientProtocolLiquidity();
    }

    totalFloatingBorrowShares += borrowShares;
    accounts[borrower].floatingBorrowShares += borrowShares;

    emit Borrow(msg.sender, receiver, borrower, assets, borrowShares);
    emitMarketUpdate();

    auditor.checkBorrow(this, borrower);
    asset.safeTransfer(receiver, assets);
  }

  /// @notice Repays a certain amount of assets to the floating pool.
  /// @param assets assets to be subtracted from the borrower's accountability.
  /// @param borrower address of the account that has the debt.
  /// @return actualRepay the actual amount that should be transferred into the protocol.
  /// @return borrowShares subtracted shares from the borrower's accountability.
  function repay(
    uint256 assets,
    address borrower
  ) public virtual whenNotPaused returns (uint256 actualRepay, uint256 borrowShares) {
    (actualRepay, borrowShares) = noTransferRefund(previewRepay(assets), borrower);
    emitMarketUpdate();
    asset.safeTransferFrom(msg.sender, address(this), actualRepay);
  }

  /// @notice Repays a certain amount of shares to the floating pool.
  /// @param borrowShares shares to be subtracted from the borrower's accountability.
  /// @param borrower address of the account that has the debt.
  /// @return assets subtracted assets from the borrower's accountability.
  /// @return actualShares actual subtracted shares from the borrower's accountability.
  function refund(
    uint256 borrowShares,
    address borrower
  ) public virtual whenNotPaused returns (uint256 assets, uint256 actualShares) {
    (assets, actualShares) = noTransferRefund(borrowShares, borrower);
    emitMarketUpdate();
    asset.safeTransferFrom(msg.sender, address(this), assets);
  }

  /// @notice Allows to (partially) repay a floating borrow. It does not transfer assets.
  /// @param borrowShares shares to be subtracted from the borrower's accountability.
  /// @param borrower the address of the account that has the debt.
  /// @return assets the actual amount that should be transferred into the protocol.
  /// @return actualShares actual subtracted shares from the borrower's accountability.
  function noTransferRefund(
    uint256 borrowShares,
    address borrower
  ) internal returns (uint256 assets, uint256 actualShares) {
    handleRewards(true, borrower);

    depositToTreasury(updateFloatingDebt());
    Account storage account = accounts[borrower];
    uint256 accountBorrowShares = account.floatingBorrowShares;
    actualShares = Math.min(borrowShares, accountBorrowShares);
    assets = previewRefund(actualShares);

    if (assets == 0) revert ZeroRepay();

    floatingDebt -= assets;
    account.floatingBorrowShares = accountBorrowShares - actualShares;
    totalFloatingBorrowShares -= actualShares;

    emit Repay(msg.sender, borrower, assets, actualShares);
  }

  /// @notice Deposits a certain amount to a maturity.
  /// @param maturity maturity date where the assets will be deposited.
  /// @param assets amount to receive from the msg.sender.
  /// @param minAssetsRequired minimum amount of assets required by the depositor for the transaction to be accepted.
  /// @param receiver address that will be able to withdraw the deposited assets.
  /// @return positionAssets total amount of assets (principal + fee) to be withdrawn at maturity.
  function depositAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 minAssetsRequired,
    address receiver
  ) public virtual whenNotPaused whenNotFrozen returns (uint256 positionAssets) {
    if (assets == 0) revert ZeroDeposit();
    // reverts on failure
    FixedLib.checkPoolState(maturity, maxFuturePools, FixedLib.State.VALID, FixedLib.State.NONE);

    FixedLib.Pool storage pool = fixedPools[maturity];

    uint256 backupEarnings = pool.accrueEarnings(maturity);
    depositToTreasury(updateFloatingDebt());
    floatingAssets += backupEarnings;

    handleRewards(false, receiver);

    (uint256 fee, uint256 backupFee) = pool.calculateDeposit(assets, backupFeeRate);
    positionAssets = assets + fee;
    if (positionAssets < minAssetsRequired) revert Disagreement();

    floatingBackupBorrowed -= pool.deposit(assets);
    pool.unassignedEarnings -= fee + backupFee;
    earningsAccumulator += backupFee;

    // update account's position
    FixedLib.Position storage position = fixedDepositPositions[maturity][receiver];

    // if account doesn't have a current position, add it to the list
    if (position.principal == 0) {
      Account storage account = accounts[receiver];
      account.fixedDeposits = account.fixedDeposits.setMaturity(maturity);
    }

    fixedConsolidated[receiver].deposits += assets;
    fixedOps.deposits += assets;
    position.principal += assets;
    position.fee += fee;

    emit DepositAtMaturity(maturity, msg.sender, receiver, assets, fee);
    emitMarketUpdate();
    emitFixedEarningsUpdate(maturity);

    asset.safeTransferFrom(msg.sender, address(this), assets);
  }

  /// @notice Borrows a certain amount from a maturity.
  /// @param maturity maturity date for repayment.
  /// @param assets amount to be sent to receiver and repaid by borrower.
  /// @param maxAssets maximum amount of debt that the account is willing to accept.
  /// @param receiver address that will receive the borrowed assets.
  /// @param borrower address that will repay the borrowed assets.
  /// @return assetsOwed total amount of assets (principal + fee) to be repaid at maturity.
  function borrowAtMaturity(
    uint256 maturity,
    uint256 assets,
    uint256 maxAssets,
    address receiver,
    address borrower
  ) external whenNotPaused whenNotFrozen returns (uint256 assetsOwed) {
    if (assets == 0) revert ZeroBorrow();
    // reverts on failure
    FixedLib.checkPoolState(maturity, maxFuturePools, FixedLib.State.VALID, FixedLib.State.NONE);

    FixedLib.Pool storage pool = fixedPools[maturity];
    depositToTreasury(updateFloatingDebt());
    floatingAssets += pool.accrueEarnings(maturity);

    handleRewards(true, borrower);

    {
      uint256 backupDebtAddition = pool.borrow(assets);
      if (backupDebtAddition != 0) {
        uint256 newFloatingBackupBorrowed = floatingBackupBorrowed + backupDebtAddition;
        if (newFloatingBackupBorrowed + floatingDebt > floatingAssets.mulWadDown(1e18 - reserveFactor)) {
          revert InsufficientProtocolLiquidity();
        }
        floatingBackupBorrowed = newFloatingBackupBorrowed;
      }
    }
    uint256 fee = assets.mulWadUp(_getFixedRate(maturity, pool).mulDivDown(maturity - block.timestamp, 365 days));
    assetsOwed = assets + fee;

    // validate that the account is not taking arbitrary fees
    if (assetsOwed > maxAssets) revert Disagreement();

    spendAllowance(borrower, assetsOwed);

    {
      // if account doesn't have a current position, add it to the list
      FixedLib.Position storage position = fixedBorrowPositions[maturity][borrower];
      if (position.principal == 0) {
        Account storage account = accounts[borrower];
        account.fixedBorrows = account.fixedBorrows.setMaturity(maturity);
      }

      // calculate what portion of the fees are to be accrued and what portion goes to earnings accumulator
      (uint256 newUnassignedEarnings, uint256 newBackupEarnings) = pool.distributeEarnings(
        chargeTreasuryFee(fee),
        assets
      );
      if (newUnassignedEarnings != 0) pool.unassignedEarnings += newUnassignedEarnings;
      collectFreeLunch(newBackupEarnings);

      fixedBorrowPositions[maturity][borrower] = FixedLib.Position(position.principal + assets, position.fee + fee);
    }
    fixedConsolidated[borrower].borrows += assets;
    fixedOps.borrows += assets;

    emit BorrowAtMaturity(maturity, msg.sender, receiver, borrower, assets, fee);
    emitMarketUpdate();
    emitFixedEarningsUpdate(maturity);

    auditor.checkBorrow(this, borrower);
    asset.safeTransfer(receiver, assets);
  }

  /// @notice Withdraws a certain amount from a maturity.
  /// @param maturity maturity date where the assets will be withdrawn.
  /// @param positionAssets position size to be reduced.
  /// @param minAssetsRequired minimum amount required by the account (if discount included for early withdrawal).
  /// @param receiver address that will receive the withdrawn assets.
  /// @param owner address that previously deposited the assets.
  /// @return assetsDiscounted amount of assets withdrawn (can include a discount for early withdraw).
  function withdrawAtMaturity(
    uint256 maturity,
    uint256 positionAssets,
    uint256 minAssetsRequired,
    address receiver,
    address owner
  ) public virtual whenNotPaused returns (uint256 assetsDiscounted) {
    FixedLib.Pool storage pool;
    FixedLib.Position memory position;
    (assetsDiscounted, pool, position, positionAssets) = _prepareWithdrawAtMaturity(
      maturity,
      positionAssets,
      minAssetsRequired,
      owner
    );

    spendAllowance(owner, assetsDiscounted);

    _processWithdrawAtMaturity(pool, position, maturity, positionAssets, owner, assetsDiscounted);

    emit WithdrawAtMaturity(maturity, msg.sender, receiver, owner, positionAssets, assetsDiscounted);
    asset.safeTransfer(receiver, assetsDiscounted);
  }

  function _prepareWithdrawAtMaturity(
    uint256 maturity,
    uint256 positionAssets,
    uint256 minAssetsRequired,
    address owner
  )
    internal
    returns (
      uint256 assetsDiscounted,
      FixedLib.Pool storage pool,
      FixedLib.Position memory position,
      uint256 effectiveAssets
    )
  {
    if (positionAssets == 0) revert ZeroWithdraw();
    // reverts on failure
    FixedLib.checkPoolState(maturity, maxFuturePools, FixedLib.State.VALID, FixedLib.State.MATURED);

    pool = fixedPools[maturity];
    depositToTreasury(updateFloatingDebt());
    floatingAssets += pool.accrueEarnings(maturity);

    handleRewards(false, owner);

    position = fixedDepositPositions[maturity][owner];
    effectiveAssets = positionAssets > position.principal + position.fee
      ? position.principal + position.fee
      : positionAssets;

    {
      // remove the supply from the fixed rate pool
      uint256 newFloatingBackupBorrowed = floatingBackupBorrowed +
        pool.withdraw(
          FixedLib.Position(position.principal, position.fee).scaleProportionally(effectiveAssets).principal
        );
      if (newFloatingBackupBorrowed + floatingDebt > floatingAssets) revert InsufficientProtocolLiquidity();
      floatingBackupBorrowed = newFloatingBackupBorrowed;
    }

    // verify if there are any penalties/fee for the account because of early withdrawal, if so discount
    if (block.timestamp < maturity) {
      assetsDiscounted = effectiveAssets.divWadDown(
        1e18 + _getFixedRate(maturity, pool).mulDivDown(maturity - block.timestamp, 365 days)
      );
    } else {
      assetsDiscounted = effectiveAssets;
    }

    if (assetsDiscounted < minAssetsRequired) revert Disagreement();
  }

  function _processWithdrawAtMaturity(
    FixedLib.Pool storage pool,
    FixedLib.Position memory position,
    uint256 maturity,
    uint256 positionAssets,
    address owner,
    uint256 assetsDiscounted
  ) internal {
    // all the fees go to unassigned or to the floating pool
    (uint256 unassignedEarnings, uint256 newBackupEarnings) = pool.distributeEarnings(
      chargeTreasuryFee(positionAssets - assetsDiscounted),
      assetsDiscounted
    );
    pool.unassignedEarnings += unassignedEarnings;
    collectFreeLunch(newBackupEarnings);

    {
      uint256 principal = position.principal;
      // the account gets discounted the full amount
      uint256 principalCovered = principal - position.reduceProportionally(positionAssets).principal;
      fixedConsolidated[owner].deposits -= principalCovered;
      fixedOps.deposits -= principalCovered;
    }
    if (position.principal | position.fee == 0) {
      delete fixedDepositPositions[maturity][owner];
      Account storage account = accounts[owner];
      account.fixedDeposits = account.fixedDeposits.clearMaturity(maturity);
    } else {
      // proportionally reduce the values
      fixedDepositPositions[maturity][owner] = position;
    }

    emitMarketUpdate();
    emitFixedEarningsUpdate(maturity);
  }

  /// @notice Repays a certain amount to a maturity.
  /// @param maturity maturity date where the assets will be repaid.
  /// @param positionAssets amount to be paid for the borrower's debt.
  /// @param maxAssets maximum amount of debt that the account is willing to accept to be repaid.
  /// @param borrower address of the account that has the debt.
  /// @return actualRepayAssets the actual amount that was transferred into the protocol.
  function repayAtMaturity(
    uint256 maturity,
    uint256 positionAssets,
    uint256 maxAssets,
    address borrower
  ) public virtual whenNotPaused returns (uint256 actualRepayAssets) {
    // reverts on failure
    FixedLib.checkPoolState(maturity, maxFuturePools, FixedLib.State.VALID, FixedLib.State.MATURED);

    actualRepayAssets = noTransferRepayAtMaturity(maturity, positionAssets, maxAssets, borrower, true);
    emitMarketUpdate();

    asset.safeTransferFrom(msg.sender, address(this), actualRepayAssets);
  }

  /// @notice Allows to (partially) repay a fixed rate position. It does not transfer assets.
  /// @param maturity the maturity to access the pool.
  /// @param positionAssets the amount of debt of the pool that should be paid.
  /// @param maxAssets maximum amount of debt that the account is willing to accept to be repaid.
  /// @param borrower the address of the account that has the debt.
  /// @param canDiscount should early repay discounts be applied.
  /// @return actualRepayAssets the actual amount that should be transferred into the protocol.
  function noTransferRepayAtMaturity(
    uint256 maturity,
    uint256 positionAssets,
    uint256 maxAssets,
    address borrower,
    bool canDiscount
  ) internal returns (uint256 actualRepayAssets) {
    if (positionAssets == 0) revert ZeroRepay();

    FixedLib.Pool storage pool = fixedPools[maturity];

    uint256 backupEarnings = pool.accrueEarnings(maturity);
    depositToTreasury(updateFloatingDebt());
    floatingAssets += backupEarnings;

    FixedLib.Position memory position = fixedBorrowPositions[maturity][borrower];

    uint256 debtCovered = Math.min(positionAssets, position.principal + position.fee);

    uint256 principalCovered = FixedLib
      .Position(position.principal, position.fee)
      .scaleProportionally(debtCovered)
      .principal;

    handleRewards(true, borrower);

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

    uint256 principal = position.principal;
    // update the account position
    principalCovered = principal - position.reduceProportionally(debtCovered).principal;
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
    emitFixedEarningsUpdate(maturity);
  }

  /// @notice Liquidates undercollateralized fixed/floating (or both) position(s).
  /// @dev Msg.sender liquidates borrower's position(s) and repays a certain amount of debt for the floating pool,
  /// or/and for multiple fixed pools, seizing a portion of borrower's collateral.
  /// @param borrower account that has an outstanding debt across floating or fixed pools.
  /// @param maxAssets maximum amount of debt that the liquidator is willing to accept. (it can be less)
  /// @param seizeMarket market from which the collateral will be seized to give to the liquidator.
  /// @return repaidAssets actual amount repaid.
  function liquidate(
    address borrower,
    uint256 maxAssets,
    Market seizeMarket
  ) public virtual whenNotPaused returns (uint256 repaidAssets) {
    if (msg.sender == borrower) revert SelfLiquidation();
    floatingAssets += accrueAccumulatedEarnings();

    maxAssets = auditor.checkLiquidation(this, seizeMarket, borrower, maxAssets);
    if (maxAssets == 0) revert ZeroRepay();

    Account storage account = accounts[borrower];

    {
      uint256 packedMaturities = account.fixedBorrows;
      uint256 maturity = packedMaturities & ((1 << 32) - 1);
      packedMaturities = packedMaturities >> 32;
      while (packedMaturities != 0 && maxAssets != 0) {
        if (packedMaturities & 1 != 0) {
          uint256 actualRepay;
          if (block.timestamp < maturity) {
            actualRepay = noTransferRepayAtMaturity(maturity, maxAssets, maxAssets, borrower, false);
            maxAssets -= actualRepay;
          } else {
            uint256 position;
            {
              FixedLib.Position storage p = fixedBorrowPositions[maturity][borrower];
              position = p.principal + p.fee;
            }
            uint256 debt = position + position.mulWadDown((block.timestamp - maturity) * penaltyRate);
            actualRepay = debt > maxAssets ? maxAssets.mulDivDown(position, debt) : maxAssets;

            if (actualRepay == 0) maxAssets = 0;
            else {
              actualRepay = noTransferRepayAtMaturity(maturity, actualRepay, maxAssets, borrower, false);
              maxAssets -= actualRepay;
            }
          }
          repaidAssets += actualRepay;
        }
        packedMaturities >>= 1;
        maturity += FixedLib.INTERVAL;
      }
    }

    if (maxAssets != 0 && account.floatingBorrowShares != 0) {
      uint256 borrowShares = previewRepay(maxAssets);
      if (borrowShares != 0) {
        (uint256 actualRepayAssets, ) = noTransferRefund(borrowShares, borrower);
        repaidAssets += actualRepayAssets;
      }
    }

    // reverts on failure
    (uint256 lendersAssets, uint256 seizeAssets) = auditor.calculateSeize(this, seizeMarket, borrower, repaidAssets);
    earningsAccumulator += lendersAssets;

    asset.safeTransferFrom(msg.sender, address(this), repaidAssets + lendersAssets);

    if (address(seizeMarket) == address(this)) {
      internalSeize(this, msg.sender, borrower, seizeAssets);
    } else {
      seizeMarket.seize(msg.sender, borrower, seizeAssets);

      emitMarketUpdate();
    }

    emit Liquidate(msg.sender, borrower, repaidAssets, lendersAssets, seizeMarket, seizeAssets);

    auditor.handleBadDebt(borrower);
  }

  /// @notice Clears floating and fixed debt for an account spreading the losses to the `earningsAccumulator`.
  /// @dev Can only be called from the auditor.
  /// @param borrower account with insufficient collateral to be cleared the debt.
  function clearBadDebt(address borrower) external {
    if (msg.sender != address(auditor)) revert NotAuditor();

    floatingAssets += accrueAccumulatedEarnings();
    Account storage account = accounts[borrower];
    uint256 accumulator = earningsAccumulator;
    uint256 totalBadDebt = 0;
    uint256 packedMaturities = account.fixedBorrows;
    uint256 maturity = packedMaturities & ((1 << 32) - 1);
    packedMaturities = packedMaturities >> 32;
    while (packedMaturities != 0) {
      if (packedMaturities & 1 != 0) {
        FixedLib.Position storage position = fixedBorrowPositions[maturity][borrower];
        uint256 badDebt = position.principal + position.fee;
        if (accumulator >= badDebt) {
          handleRewards(true, borrower);
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
    if (account.floatingBorrowShares != 0 && (accumulator = previewRepay(accumulator)) != 0) {
      (uint256 badDebt, ) = noTransferRefund(accumulator, borrower);
      totalBadDebt += badDebt;
    }
    if (totalBadDebt != 0) {
      earningsAccumulator -= totalBadDebt;
      emit SpreadBadDebt(borrower, totalBadDebt);
    }
    emitMarketUpdate();
  }

  /// @notice Public function to seize a certain amount of assets.
  /// @dev Public function for liquidator to seize borrowers assets in the floating pool.
  /// This function will only be called from another Market, on `liquidation` calls.
  /// That's why msg.sender needs to be passed to the internal function (to be validated as a Market).
  /// @param liquidator address which will receive the seized assets.
  /// @param borrower address from which the assets will be seized.
  /// @param assets amount to be removed from borrower's possession.
  function seize(address liquidator, address borrower, uint256 assets) external whenNotPaused {
    internalSeize(Market(msg.sender), liquidator, borrower, assets);
  }

  /// @notice Internal function to seize a certain amount of assets.
  /// @dev Internal function for liquidator to seize borrowers assets in the floating pool.
  /// Will only be called from this Market on `liquidation` or through `seize` calls from another Market.
  /// That's why msg.sender needs to be passed to the internal function (to be validated as a Market).
  /// @param seizeMarket address which is calling the seize function (see `seize` public function).
  /// @param liquidator address which will receive the seized assets.
  /// @param borrower address from which the assets will be seized.
  /// @param assets amount to be removed from borrower's possession.
  function internalSeize(Market seizeMarket, address liquidator, address borrower, uint256 assets) internal {
    if (assets == 0) revert ZeroWithdraw();

    // reverts on failure
    auditor.checkSeize(seizeMarket, this);

    handleRewards(false, borrower);
    uint256 shares = previewWithdraw(assets);
    beforeWithdraw(assets, shares);
    _burn(borrower, shares);
    emit Withdraw(msg.sender, liquidator, borrower, assets, shares);
    emit Seize(liquidator, borrower, assets);
    emitMarketUpdate();

    asset.safeTransfer(liquidator, assets);
  }

  /// @notice Hook to update the floating pool average, floating pool balance and distribute earnings from accumulator.
  /// @param assets amount of assets to be withdrawn from the floating pool.
  function beforeWithdraw(uint256 assets, uint256) internal override whenNotPaused {
    updateAverages();
    depositToTreasury(updateFloatingDebt());
    uint256 earnings = accrueAccumulatedEarnings();
    uint256 newFloatingAssets = floatingAssets + earnings - assets;
    // check if the underlying liquidity that the account wants to withdraw is borrowed
    if (floatingBackupBorrowed + floatingDebt > newFloatingAssets) revert InsufficientProtocolLiquidity();
    floatingAssets = newFloatingAssets;
  }

  /// @notice Hook to update the floating pool average, floating pool balance and distribute earnings from accumulator.
  /// @param assets amount of assets to be deposited to the floating pool.
  function afterDeposit(uint256 assets, uint256 shares) internal override whenNotPaused whenNotFrozen {
    if (shares + totalSupply > maxSupply) revert MaxSupplyExceeded();

    updateAverages();
    uint256 treasuryFee = updateFloatingDebt();
    uint256 earnings = accrueAccumulatedEarnings();
    floatingAssets += earnings + assets;
    depositToTreasury(treasuryFee);
    emitMarketUpdate();
  }

  /// @notice Withdraws the owner's floating pool assets to the receiver address.
  /// @dev Makes sure that the owner doesn't have shortfall after withdrawing.
  /// @param assets amount of underlying to be withdrawn.
  /// @param receiver address to which the assets will be transferred.
  /// @param owner address which owns the floating pool assets.
  /// @return shares amount of shares redeemed for underlying asset.
  function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
    auditor.checkShortfall(this, owner, assets);
    handleRewards(false, owner);
    shares = super.withdraw(assets, receiver, owner);
    emitMarketUpdate();
  }

  /// @notice Redeems the owner's floating pool assets to the receiver address.
  /// @dev Makes sure that the owner doesn't have shortfall after withdrawing.
  /// @param shares amount of shares to be redeemed for underlying asset.
  /// @param receiver address to which the assets will be transferred.
  /// @param owner address which owns the floating pool assets.
  /// @return assets amount of underlying asset that was withdrawn.
  function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
    auditor.checkShortfall(this, owner, previewRedeem(shares));
    handleRewards(false, owner);
    assets = super.redeem(shares, receiver, owner);
    emitMarketUpdate();
  }

  function _mint(address to, uint256 amount) internal override {
    handleRewards(false, to);
    super._mint(to, amount);
  }

  /// @notice Moves amount of shares from the caller's account to `to`.
  /// @dev Makes sure that the caller doesn't have shortfall after transferring.
  /// @param to address to which the assets will be transferred.
  /// @param shares amount of shares to be transferred.
  // solhint-disable-next-line no-unused-vars
  function transfer(address to, uint256 shares) public virtual override returns (bool) {
    return abi.decode(delegateToExtension(), (bool));
  }

  /// @notice Moves amount of shares from `from` to `to` using the allowance mechanism.
  /// @dev Makes sure that `from` address doesn't have shortfall after transferring.
  /// @param from address from which the assets will be transferred.
  /// @param to address to which the assets will be transferred.
  /// @param shares amount of shares to be transferred.
  // solhint-disable-next-line no-unused-vars
  function transferFrom(address from, address to, uint256 shares) public virtual override returns (bool) {
    return abi.decode(delegateToExtension(), (bool));
  }

  /// @notice Gets current snapshot for an account across all maturities.
  /// @param account account to return status snapshot in the specified maturity date.
  /// @return the amount deposited to the floating pool and the amount owed to floating and fixed pools.
  function accountSnapshot(address account) external view returns (uint256, uint256) {
    return (convertToAssets(balanceOf[account]), previewDebt(account));
  }

  /// @notice Gets all borrows and penalties for an account.
  /// @param borrower account to return status snapshot for fixed and floating borrows.
  /// @return debt the total debt, denominated in number of assets.
  function previewDebt(address borrower) public view returns (uint256 debt) {
    Account storage account = accounts[borrower];
    uint256 memPenaltyRate = penaltyRate;
    uint256 packedMaturities = account.fixedBorrows;
    uint256 maturity = packedMaturities & ((1 << 32) - 1);
    packedMaturities = packedMaturities >> 32;
    // calculate all maturities using the base maturity and the following bits representing the following intervals
    while (packedMaturities != 0) {
      if (packedMaturities & 1 != 0) {
        FixedLib.Position storage position = fixedBorrowPositions[maturity][borrower];
        uint256 positionAssets = position.principal + position.fee;

        debt += positionAssets;

        if (block.timestamp > maturity) {
          debt += positionAssets.mulWadDown((block.timestamp - maturity) * memPenaltyRate);
        }
      }
      packedMaturities >>= 1;
      maturity += FixedLib.INTERVAL;
    }
    // calculate floating borrowed debt
    uint256 shares = account.floatingBorrowShares;
    if (shares != 0) debt += previewRefund(shares);
  }

  /// @notice Charges treasury fee to certain amount of earnings.
  /// @param earnings amount of earnings.
  /// @return earnings minus the fees charged by the treasury.
  function chargeTreasuryFee(uint256 earnings) internal returns (uint256) {
    uint256 fee = earnings.mulWadDown(treasuryFeeRate);
    depositToTreasury(fee);
    return earnings - fee;
  }

  /// @notice Collects all earnings that are charged to borrowers that make use of fixed pool deposits' assets.
  /// @param earnings amount of earnings.
  function collectFreeLunch(uint256 earnings) internal {
    if (earnings == 0) return;

    if (treasuryFeeRate != 0) {
      depositToTreasury(earnings);
    } else {
      earningsAccumulator += earnings;
    }
  }

  /// @notice Simulates the effects of a borrow at the current time, given current contract conditions.
  /// @param assets amount of assets to borrow.
  /// @return amount of shares that will be asigned to the account after the borrow.
  function previewBorrow(uint256 assets) public view returns (uint256) {
    uint256 supply = totalFloatingBorrowShares; // Saves an extra SLOAD if totalFloatingBorrowShares is non-zero.

    return supply == 0 ? assets : assets.mulDivUp(supply, totalFloatingBorrowAssets());
  }

  /// @notice Simulates the effects of a repay at the current time, given current contract conditions.
  /// @param assets amount of assets to repay.
  /// @return amount of shares that will be subtracted from the account after the repay.
  function previewRepay(uint256 assets) public view returns (uint256) {
    uint256 supply = totalFloatingBorrowShares; // Saves an extra SLOAD if totalFloatingBorrowShares is non-zero.

    return supply == 0 ? assets : assets.mulDivDown(supply, totalFloatingBorrowAssets());
  }

  /// @notice Simulates the effects of a refund at the current time, given current contract conditions.
  /// @param shares amount of shares to subtract from caller's accountability.
  /// @return amount of assets that will be repaid.
  function previewRefund(uint256 shares) public view returns (uint256) {
    uint256 supply = totalFloatingBorrowShares; // Saves an extra SLOAD if totalFloatingBorrowShares is non-zero.

    return supply == 0 ? shares : shares.mulDivUp(totalFloatingBorrowAssets(), supply);
  }

  /// @notice Checks msg.sender's allowance over account's assets.
  /// @param account account in which the allowance will be checked.
  /// @param assets assets from account that msg.sender wants to operate on.
  function spendAllowance(address account, uint256 assets) internal {
    if (msg.sender != account) {
      uint256 allowed = allowance[account][msg.sender]; // saves gas for limited approvals.

      if (allowed != type(uint256).max) allowance[account][msg.sender] = allowed - previewWithdraw(assets);
    }
  }

  /// @notice Retrieves fixed utilization of the floating pool.
  /// @dev Internal function to avoid code duplication.
  function fixedUtilization(uint256 supplied, uint256 borrowed, uint256 assets) internal pure returns (uint256) {
    return assets != 0 && borrowed > supplied ? (borrowed - supplied).divWadUp(assets) : 0;
  }

  /// @notice Returns the fixed rate of a given maturity and fixed pool supply and borrow demand.
  /// @dev Internal function to avoid code duplication.
  function _getFixedRate(uint256 maturity, FixedLib.Pool storage pool) internal view returns (uint256) {
    uint256 memFloatingAssets = floatingAssets;
    uint256 memFloatingDebt = floatingDebt;

    return
      interestRateModel.fixedRate(
        maturity,
        maxFuturePools,
        fixedUtilization(pool.supplied, pool.borrowed, memFloatingAssets),
        floatingUtilization(memFloatingAssets, memFloatingDebt),
        globalUtilization(memFloatingAssets, memFloatingDebt, floatingBackupBorrowed),
        previewGlobalUtilizationAverage(),
        maturityDebtDuration(maturity)
      );
  }

  /// @notice Returns the duration of the debt of a given fixed pool.
  /// @dev Checks if a fixed borrow at a certain pool is valid given current liquidity conditions.
  /// @param maturity maturity date of the fixed pool.
  /// @return duration modified duration debt metric.
  function maturityDebtDuration(uint256 maturity) internal view returns (uint256 duration) {
    uint256 borrows;
    uint256 memFloatingAssetsAverage = previewFloatingAssetsAverage();
    {
      uint256 latestMaturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL);
      uint256 maxMaturity = latestMaturity + (maxFuturePools) * FixedLib.INTERVAL;
      for (uint256 i = latestMaturity + FixedLib.INTERVAL; i <= maxMaturity; i += FixedLib.INTERVAL) {
        FixedLib.Pool memory pool = fixedPools[i];
        uint256 backupBorrowed = pool.borrowed > pool.supplied ? pool.borrowed - pool.supplied : 0;
        duration += backupBorrowed.mulDivDown(i - block.timestamp, 365 days);
        if (i >= maturity) borrows += backupBorrowed;
      }
    }
    if (memFloatingAssetsAverage != 0) {
      if (
        !interestRateModel.canBorrowAtMaturity(
          maturity,
          borrows,
          memFloatingAssetsAverage,
          floatingBackupBorrowed,
          maxFuturePools
        )
      ) {
        revert InsufficientProtocolLiquidity();
      }
      return duration.divWadDown(memFloatingAssetsAverage);
    }
    return 0;
  }

  /// @notice Emits FixedEarningsUpdate event.
  /// @dev Internal function to avoid code duplication.
  function emitFixedEarningsUpdate(uint256 maturity) internal {
    emit FixedEarningsUpdate(block.timestamp, maturity, fixedPools[maturity].unassignedEarnings);
  }

  /// @notice Sets the rewards controller to update account rewards when operating with the Market.
  /// @param rewardsController_ new rewards controller.
  function setRewardsController(RewardsController rewardsController_) public virtual onlyRole(DEFAULT_ADMIN_ROLE) {
    rewardsController = rewardsController_;
    emit RewardsControllerSet(rewardsController_);
  }

  /// @notice Sets the treasury variables.
  /// @param treasury_ address of the treasury that will receive the minted eTokens.
  /// @param treasuryFeeRate_ represented with 18 decimals.
  function setTreasury(address treasury_, uint256 treasuryFeeRate_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    depositToTreasury(updateFloatingDebt());
    treasury = treasury_;
    treasuryFeeRate = treasuryFeeRate_;
    emit TreasurySet(treasury_, treasuryFeeRate_);
  }

  /// @notice Sets the pause state to true in case of emergency, triggered by an authorized account.
  function pause() external onlyPausingRoles {
    _pause();
  }

  /// @notice Sets the pause state to false when threat is gone, triggered by an authorized account.
  function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  /// @notice Sets `isFrozen` state, triggered by an authorized account.
  function setFrozen(bool isFrozen_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (isFrozen == isFrozen_) return;
    isFrozen = isFrozen_;
    emit Frozen(msg.sender, isFrozen_);
  }

  /// @dev Throws if the market is frozen.
  function requireNotFrozen() internal view {
    if (isFrozen) revert MarketFrozen();
  }

  /// @dev Modifier to make a function callable only when the market is not frozen.
  modifier whenNotFrozen() {
    requireNotFrozen();
    _;
  }

  /// @dev Throws if the caller is not an `EMERGENCY_ADMIN_ROLE` or `PAUSER_ROLE`.
  function requirePausingRoles() internal view {
    if (!hasRole(EMERGENCY_ADMIN_ROLE, msg.sender) && !hasRole(PAUSER_ROLE, msg.sender)) {
      revert NotPausingRole();
    }
  }

  /// @dev Modifier to make a function callable only by pausing roles.
  modifier onlyPausingRoles() {
    requirePausingRoles();
    _;
  }

  function delegateToExtension() internal returns (bytes memory) {
    /// @custom:oz-upgrades-unsafe-allow delegatecall
    // solhint-disable-next-line avoid-low-level-calls
    (bool success, bytes memory data) = address(extension).delegatecall(msg.data);
    if (!success) {
      if (data.length == 0) revert ExtensionFailed();
      // solhint-disable-next-line no-inline-assembly
      assembly ("memory-safe") {
        revert(add(32, data), mload(data))
      }
    }
    return data;
  }

  /// @notice Event emitted when an account borrows amount of assets from a floating pool.
  /// @param caller address which borrowed the asset.
  /// @param receiver address that received the borrowed assets.
  /// @param borrower address which will be repaying the borrowed assets.
  /// @param assets amount of assets that were borrowed.
  /// @param shares amount of borrow shares assigned to the account.
  event Borrow(
    address indexed caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 shares
  );

  /// @notice Emitted when an account repays amount of assets to a floating pool.
  /// @param caller address which repaid the previously borrowed amount.
  /// @param borrower address which had the original debt.
  /// @param assets amount of assets that was repaid.
  /// @param shares amount of borrow shares that were subtracted from the account's accountability.
  event Repay(address indexed caller, address indexed borrower, uint256 assets, uint256 shares);

  /// @notice Emitted when an account deposits an amount of an asset to a certain fixed rate pool,
  /// collecting fees at the end of the period.
  /// @param maturity maturity at which the account will be able to collect his deposit + his fee.
  /// @param caller address which deposited the assets.
  /// @param owner address that will be able to withdraw the deposited assets.
  /// @param assets amount of the asset that were deposited.
  /// @param fee is the extra amount that it will be collected at maturity.
  event DepositAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed owner,
    uint256 assets,
    uint256 fee
  );

  /// @notice Emitted when an account withdraws from a fixed rate pool.
  /// @param maturity maturity where the account withdraw its deposits.
  /// @param caller address which withdraw the asset.
  /// @param receiver address which will be collecting the assets.
  /// @param owner address which had the assets withdrawn.
  /// @param positionAssets position size reduced.
  /// @param assets amount of assets withdrawn (can include a discount for early withdraw).
  event WithdrawAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed owner,
    uint256 positionAssets,
    uint256 assets
  );

  /// @notice Emitted when an account borrows amount of an asset from a certain maturity date.
  /// @param maturity maturity in which the account will have to repay the loan.
  /// @param caller address which borrowed the asset.
  /// @param receiver address that received the borrowed assets.
  /// @param borrower address which will be repaying the borrowed assets.
  /// @param assets amount of the asset that were borrowed.
  /// @param fee extra amount that will need to be paid at maturity.
  event BorrowAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 fee
  );

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

  /// @notice Emitted when an account's position had a liquidation.
  /// @param receiver address which repaid the previously borrowed amount.
  /// @param borrower address which had the original debt.
  /// @param assets amount of the asset that were repaid.
  /// @param lendersAssets incentive paid to lenders.
  /// @param seizeMarket address of the asset that were seized by the liquidator.
  /// @param seizedAssets amount seized of the collateral.
  event Liquidate(
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 lendersAssets,
    Market indexed seizeMarket,
    uint256 seizedAssets
  );

  /// @notice Emitted when an account's collateral has been seized.
  /// @param liquidator address which seized this collateral.
  /// @param borrower address which had the original debt.
  /// @param assets amount seized of the collateral.
  event Seize(address indexed liquidator, address indexed borrower, uint256 assets);

  /// @notice Emitted when an account is cleared from bad debt.
  /// @param borrower address which was cleared from bad debt.
  /// @param assets amount that was subtracted from the borrower's debt and spread to the `earningsAccumulator`.
  event SpreadBadDebt(address indexed borrower, uint256 assets);

  /// @notice Emitted when the treasury variables are changed by admin.
  /// @param treasury address of the treasury that will receive the minted eTokens.
  /// @param treasuryFeeRate represented with 18 decimals.
  event TreasurySet(address indexed treasury, uint256 treasuryFeeRate);

  /// @notice Emitted when the rewardsController is changed by admin.
  /// @param rewardsController new rewards controller to update account rewards when operating with the Market.
  event RewardsControllerSet(RewardsController indexed rewardsController);

  /// @notice Emitted when the earnings of a maturity are updated.
  /// @param timestamp current timestamp.
  /// @param maturity maturity date where the earnings were updated.
  /// @param unassignedEarnings pending unassigned earnings.
  event FixedEarningsUpdate(uint256 timestamp, uint256 indexed maturity, uint256 unassignedEarnings);

  /// @notice Emitted when `account` sets the `isFrozen` flag.
  event Frozen(address indexed account, bool isFrozen);
}

error Disagreement();
error ExtensionFailed();
error InsufficientProtocolLiquidity();
error MarketFrozen();
error MaxSupplyExceeded();
error NotAuditor();
error NotPausingRole();
error SelfLiquidation();
error ZeroBorrow();
error ZeroDeposit();
error ZeroRepay();
error ZeroWithdraw();
