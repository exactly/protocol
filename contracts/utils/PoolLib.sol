// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TSUtils } from "./TSUtils.sol";

library PoolLib {
  using FixedPointMathLib for uint256;

  /// @notice struct that helps manage the maturity pools and also keep.
  /// @param borrowed total amount borrowed at the MP.
  /// @param supplied total amount supplied to the MP.
  /// @param suppliedSP total amount borrowed over time from the SP.
  /// It only increases, and it's the last debt to be repaid at maturity.
  /// @param earnings total amount of earnings to be collected at maturity.
  /// This earnings haven't accrued yet (see: lastAccrue). Each interaction with the MP, some of these earnings
  /// are accrued to earningsSP. This is done by:
  ///     EARNINGSSP += DAYS(NOW - LAST_ACCRUE) * EARNINGS / DAYS(MATURITY_DATE - LAST_ACCRUE);
  /// If there's a new deposit to the MP, the commission for that deposit comes out of the future earnings:
  ///     NEWCOMMISSION = DEPOSIT * EARNINGS / (SUPPLIEDSP + DEPOSIT);
  ///     EARNINGS -= NEWCOMMISSION;
  /// @param earningsSP total amount of earnings that already belong to the SP.
  /// @param lastAccrue timestamp for the last time that some of the earnings have been transferred to earningsSP.
  /// SP gained some earnings for having supported the loans.
  struct MaturityPool {
    uint256 borrowed;
    uint256 supplied;
    uint256 suppliedSP;
    uint256 earningsUnassigned;
    uint256 lastAccrue;
  }

  struct Position {
    uint256 principal;
    uint256 fee;
  }

  uint256 public constant MATURITY_ALL = type(uint256).max;

  /// @notice function that registers an operation to add money to maturity pool.
  /// @param pool maturity pool where money will be added.
  /// @param amount amount to be added to the maturity pool.
  function depositMoney(MaturityPool storage pool, uint256 amount) internal returns (uint256 smartPoolDebtReduction) {
    uint256 suppliedSP = pool.suppliedSP;
    uint256 supplied = pool.supplied;

    smartPoolDebtReduction = Math.min(suppliedSP, amount);

    pool.supplied = supplied + amount;
    pool.suppliedSP = suppliedSP - smartPoolDebtReduction;
  }

  /// @notice function that registers an operation to add money to maturity pool.
  /// @param pool maturity pool where money will be added.
  /// @param amount amount to be added to the maturity pool.
  function repayMoney(MaturityPool storage pool, uint256 amount) internal returns (uint256 smartPoolDebtReduction) {
    uint256 suppliedSP = pool.suppliedSP;
    uint256 borrowed = pool.borrowed;

    smartPoolDebtReduction = Math.min(suppliedSP, amount);

    pool.borrowed = borrowed - amount;
    pool.suppliedSP = suppliedSP - smartPoolDebtReduction;
  }

  /// @notice registers an operation to take money out of the maturity pool that returns the new smart pool debt.
  /// @param pool maturity pool where money needs to be taken out.
  /// @param amount amount to be taken out of the pool before it matures.
  /// @return newDebtSP amount of new debt that needs to be taken out of the SP.
  function borrowMoney(
    MaturityPool storage pool,
    uint256 amount,
    uint256 maxDebt
  ) internal returns (uint256 newDebtSP) {
    uint256 newBorrowedMP = pool.borrowed + amount;
    uint256 suppliedMP = pool.supplied;
    uint256 suppliedALL = pool.suppliedSP + suppliedMP;

    if (newBorrowedMP > suppliedALL) {
      uint256 newSupplySP = newBorrowedMP - suppliedMP;

      if (newSupplySP > maxDebt) revert InsufficientProtocolLiquidity();

      // We take money out from the Smart Pool
      // because there's not enough in the MP
      newDebtSP = newBorrowedMP - suppliedALL;
      pool.suppliedSP = newSupplySP;
    }

    pool.borrowed = newBorrowedMP;
  }

  /// @notice registers an operation to withdraw money out of the maturity pool that returns the new smart pool debt.
  /// @param pool maturity pool where money needs to be withdrawn.
  /// @param amountToDiscount previous amount that the user deposited.
  /// @return newDebtSP amount of new debt that needs to be taken out of the SP.
  function withdrawMoney(
    MaturityPool storage pool,
    uint256 amountToDiscount,
    uint256 maxDebt
  ) internal returns (uint256 newDebtSP) {
    uint256 borrowedMP = pool.borrowed;
    uint256 newSuppliedMP = pool.supplied - amountToDiscount;
    uint256 newSuppliedALL = pool.suppliedSP + newSuppliedMP;

    // by reducing supply we might need to take debt from SP
    if (borrowedMP > newSuppliedALL) {
      // We take money out from the Smart Pool
      // because there's not enough in the MP
      newDebtSP = borrowedMP - newSuppliedALL;
      uint256 newSupplySP = pool.suppliedSP + newDebtSP;
      if (newSupplySP > maxDebt) revert InsufficientProtocolLiquidity();
      pool.suppliedSP = newSupplySP;
    }

    pool.supplied = newSuppliedMP;
  }

  /// @notice Internal function to accrue Smart Pool earnings.
  /// @param pool maturity pool that needs to be updated.
  /// @param maturityID timestamp in which maturity pool matures.
  function accrueEarnings(
    MaturityPool storage pool,
    uint256 maturityID,
    uint256 currentTimestamp
  ) internal returns (uint256 earningsSP) {
    uint256 lastAccrue = pool.lastAccrue;

    if (lastAccrue == maturityID) return 0;

    // seconds from last accrual to the closest:
    // maturity date or the current timestamp
    uint256 secondsSinceLastAccrue = TSUtils.secondsPre(lastAccrue, Math.min(maturityID, currentTimestamp));
    // seconds from last accrual to the maturity date
    uint256 secondsTotalToMaturity = TSUtils.secondsPre(lastAccrue, maturityID);
    pool.lastAccrue = Math.min(maturityID, currentTimestamp);

    // assign some of the earnings to be collected at maturity
    uint256 earningsUnassigned = pool.earningsUnassigned;
    earningsSP = secondsTotalToMaturity == 0
      ? 0
      : earningsUnassigned.fmul(secondsSinceLastAccrue, secondsTotalToMaturity);
    pool.earningsUnassigned = earningsUnassigned - earningsSP;
  }

  /// @notice modify positions based on a certain amount, keeping the original principal/fee ratio.
  /// @dev modifies the original struct and returns it.
  /// @param position original position to be scaled.
  /// @param amount to be used as a full value (principal + interest).
  function scaleProportionally(Position memory position, uint256 amount) internal pure returns (Position memory) {
    uint256 fee = amount.fmul(position.fee, position.principal + position.fee);
    position.principal = amount - fee;
    position.fee = fee;
    return position;
  }

  /// @notice reduce positions based on a certain amount, keeping the original principal/fee ratio.
  /// @dev modifies the original struct and returns it.
  /// @param position original position to be reduced.
  /// @param amount to be used as a full value (principal + interest).
  function reduceProportionally(Position memory position, uint256 amount) internal pure returns (Position memory) {
    uint256 fee = amount.fmul(position.fee, position.principal + position.fee);
    position.principal -= amount - fee;
    position.fee -= fee;
    return position;
  }

  /// @notice returns what part belongs to the SP or the treasury based on who supplied.
  /// @param earnings amount to be distributed as earnings between the treasury and the smart pool.
  /// @param suppliedSP current supply of the smart pool.
  /// @param amountFunded amount that will be checked if it came from smart pool or not.
  function distributeEarningsAccordingly(
    uint256 earnings,
    uint256 suppliedSP,
    uint256 amountFunded
  ) internal pure returns (uint256 earningsSP, uint256 earningsTreasury) {
    earningsTreasury = earnings.fmul(amountFunded - Math.min(suppliedSP, amountFunded), amountFunded);
    earningsSP = earnings - earningsTreasury;
  }

  /// @notice Function to add a maturityDate to the borrow positions of the user
  /// @param userBorrows packed maturity dates where the user borrowed
  /// @param maturityDate to calculate the difference in seconds to a date
  function addMaturity(uint256 userBorrows, uint256 maturityDate) internal pure returns (uint256) {
    if (userBorrows == 0) {
      // we initialize the maturity date with also the 1st bit
      // on the 33nd position ON
      return maturityDate | (1 << 32);
    }

    uint32 baseTimestamp = uint32(userBorrows % (2**32));
    if (maturityDate < baseTimestamp) {
      // If the new maturity date if lower than the base, then we need to
      // set it as the new base. We wipe clean the last 32 bits, we shift
      // the amount of INTERVALS and we set the new value with the 33rd bit ON
      uint256 weekDiff = uint32((baseTimestamp - maturityDate) / TSUtils.INTERVAL);
      if (userBorrows >> (256 - weekDiff) != 0) revert MaturityRangeTooWide();
      userBorrows = ((userBorrows >> 32) << (32 + weekDiff));
      return maturityDate | userBorrows | (1 << 32);
    } else {
      uint256 weekDiff = uint32((maturityDate - baseTimestamp) / TSUtils.INTERVAL);
      if (weekDiff > 223) revert MaturityRangeTooWide();
      return userBorrows | (1 << (32 + weekDiff));
    }
  }

  /// @dev Cleans user's position from packed maturity pools
  /// @param userBorrows packed maturity dates where the user borrowed
  /// @param maturityDate maturity date
  function removeMaturity(uint256 userBorrows, uint256 maturityDate) internal pure returns (uint256) {
    // if only the baseTimestamp is ON or is already 0
    if (userBorrows == 0 || userBorrows == maturityDate | (1 << 32)) {
      return 0;
    }

    // Trying to delete a maturityDate that it's not present
    uint32 baseTimestamp = uint32(userBorrows % (2**32));
    if (baseTimestamp > maturityDate) {
      return userBorrows;
    }

    // if the baseTimestamp is the one being cleaned
    if (maturityDate == baseTimestamp) {
      // We're wiping 32 bytes + 1 for the old base flag
      uint224 moreMaturities = uint224(userBorrows >> 33);
      uint224 intervalDiff = 1;
      while ((moreMaturities & 1) == 0 && moreMaturities != 0) {
        unchecked {
          ++intervalDiff;
        }
        moreMaturities >>= 1;
      }
      userBorrows = ((userBorrows >> (32 + intervalDiff)) << 32);
      return (maturityDate + (intervalDiff * TSUtils.INTERVAL)) | userBorrows;
    } else {
      // ...otherwise just set the bit OFF
      return userBorrows & ~(1 << (32 + ((maturityDate - baseTimestamp) / TSUtils.INTERVAL)));
    }
  }
}

error InsufficientProtocolLiquidity();
error MaturityRangeTooWide();
