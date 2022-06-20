// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TSUtils } from "./TSUtils.sol";

library PoolLib {
  using FixedPointMathLib for uint256;

  /// @notice contains the accountability of a fixed interest rate pool.
  /// @param borrowed total amount borrowed from the pool.
  /// @param supplied total amount supplied to the pool.
  /// @param earningsUnassigned total amount of earnings not yet distributed and accrued.
  /// @param lastAccrual timestamp for the last time that some earnings have been distributed to earningsSP.
  struct FixedPool {
    uint256 borrowed;
    uint256 supplied;
    uint256 earningsUnassigned;
    uint256 lastAccrual;
  }

  /// @notice contains principal and fee of a borrow or a supply position of a user in a fixed rate pool.
  /// @param principal amount borrowed or supplied to the fixed rate pool.
  /// @param fee amount of fees to be repaid or earned at the maturity of the fixed rate pool.
  struct Position {
    uint256 principal;
    uint256 fee;
  }

  /// @notice calculates the amount that a fixed rate pool borrowed from the smart pool.
  /// @param pool fixed rate pool.
  /// @return amount borrowed from the fixed rate pool.
  function smartPoolBorrowed(FixedPool storage pool) internal view returns (uint256) {
    uint256 borrowed = pool.borrowed;
    uint256 supplied = pool.supplied;
    return borrowed - Math.min(borrowed, supplied);
  }

  /// @notice registers an operation to add supply to a fixed rate pool and potentially reduce smart pool debt.
  /// @param pool fixed rate pool where an amount will be added to the supply.
  /// @param amount amount to be added to the supply.
  /// @return smartPoolDebtReduction amount that will be reduced from the smart pool debt.
  function deposit(FixedPool storage pool, uint256 amount) internal returns (uint256 smartPoolDebtReduction) {
    uint256 borrowed = pool.borrowed;
    uint256 supplied = pool.supplied;
    pool.supplied = supplied + amount;
    smartPoolDebtReduction = Math.min(borrowed - Math.min(borrowed, supplied), amount);
  }

  /// @notice registers an operation to reduce borrowed amount from a fixed rate pool
  /// and potentially reduce smart pool debt.
  /// @param pool fixed rate pool where an amount will be repaid.
  /// @param amount amount to be added to the fixed rate pool.
  /// @return smartPoolDebtReduction amount that will be reduced from the smart pool debt.
  function repay(FixedPool storage pool, uint256 amount) internal returns (uint256 smartPoolDebtReduction) {
    uint256 borrowed = pool.borrowed;
    uint256 supplied = pool.supplied;
    pool.borrowed = borrowed - amount;
    smartPoolDebtReduction = Math.min(borrowed - Math.min(borrowed, supplied), amount);
  }

  /// @notice registers an operation to increase borrowed amount of a fixed rate pool
  ///  and potentially increase smart pool debt.
  /// @param pool fixed rate pool where an amount will be borrowed.
  /// @param amount amount to be borrowed from the fixed rate pool.
  /// @return smartPoolDebtAddition amount of new debt that needs to be borrowed from the smart pool.
  function borrow(
    FixedPool storage pool,
    uint256 amount,
    uint256 maxDebt
  ) internal returns (uint256 smartPoolDebtAddition) {
    uint256 borrowed = pool.borrowed;
    uint256 newBorrowed = borrowed + amount;
    uint256 oldSupply = Math.max(borrowed, pool.supplied);

    smartPoolDebtAddition = newBorrowed - Math.min(oldSupply, newBorrowed);

    if (smartPoolDebtAddition > maxDebt) revert InsufficientProtocolLiquidity();

    pool.borrowed = newBorrowed;
  }

  /// @notice registers an operation to reduce supply from a fixed rate pool and potentially increase smart pool debt.
  /// @param pool fixed rate pool where amount will be withdrawn.
  /// @param amountToDiscount amount to be withdrawn from the fixed rate pool.
  /// @return smartPoolDebtAddition amount of new debt that needs to be borrowed from the smart pool.
  function withdraw(
    FixedPool storage pool,
    uint256 amountToDiscount,
    uint256 maxDebt
  ) internal returns (uint256 smartPoolDebtAddition) {
    uint256 borrowed = pool.borrowed;
    uint256 supplied = pool.supplied;
    uint256 newSupply = supplied - amountToDiscount;

    smartPoolDebtAddition = Math.min(supplied, borrowed) - Math.min(newSupply, borrowed);

    if (smartPoolDebtAddition > maxDebt) revert InsufficientProtocolLiquidity();

    pool.supplied = newSupply;
  }

  /// @notice accrues smart pool earnings from earningsUnassigned based on the lastAccrual time.
  /// @param pool fixed rate pool where earnings will be accrued.
  /// @param currentTimestamp timestamp of the current transaction.
  /// @param maturity maturity date of the pool.
  /// @return earningsSP amount of earnings to be distributed to the smart pool.
  function accrueEarnings(
    FixedPool storage pool,
    uint256 maturity,
    uint256 currentTimestamp
  ) internal returns (uint256 earningsSP) {
    uint256 lastAccrual = pool.lastAccrual;

    if (lastAccrual == maturity) return 0;

    // seconds from last accrual to the closest:
    // maturity date or the current timestamp
    uint256 secondsSinceLastAccrue = TSUtils.secondsPre(lastAccrual, Math.min(maturity, currentTimestamp));
    // seconds from last accrual to the maturity date
    uint256 secondsTotalToMaturity = TSUtils.secondsPre(lastAccrual, maturity);
    pool.lastAccrual = Math.min(maturity, currentTimestamp);

    // assign some of the earnings to be collected at maturity
    uint256 earningsUnassigned = pool.earningsUnassigned;
    earningsSP = earningsUnassigned.mulDivDown(secondsSinceLastAccrue, secondsTotalToMaturity);
    pool.earningsUnassigned = earningsUnassigned - earningsSP;
  }

  /// @notice modify positions based on a certain amount, keeping the original principal/fee ratio.
  /// @dev modifies the original struct and returns it. Needs for the amount to be less than the principal and the fee
  /// @param position original position to be scaled.
  /// @param amount to be used as a full value (principal + interest).
  /// @return Position scaled position.
  function scaleProportionally(Position memory position, uint256 amount) internal pure returns (Position memory) {
    uint256 principal = amount.mulDivDown(position.principal, position.principal + position.fee);
    position.principal = principal;
    position.fee = amount - principal;
    return position;
  }

  /// @notice reduce positions based on a certain amount, keeping the original principal/fee ratio.
  /// @dev modifies the original struct and returns it.
  /// @param position original position to be reduced.
  /// @param amount to be used as a full value (principal + interest).
  /// @return Position reduced position.
  function reduceProportionally(Position memory position, uint256 amount) internal pure returns (Position memory) {
    uint256 principal = amount.mulDivDown(position.principal, position.principal + position.fee);
    position.principal -= principal;
    position.fee -= amount - principal;
    return position;
  }

  /// @notice calculates what proportion of earnings would amountFunded represent considering suppliedSP.
  /// @param earnings amount to be distributed.
  /// @param suppliedSP amount that the fixed rate pool borrowed from the smart pool.
  /// @param amountFunded amount that will be checked if came from the smart pool or fixed rate pool.
  /// @return earningsUnassigned earnings to be added to earningsUnassigned.
  /// @return earningsSP earnings to be distributed to the smart pool.
  function distributeEarningsAccordingly(
    uint256 earnings,
    uint256 suppliedSP,
    uint256 amountFunded
  ) internal pure returns (uint256 earningsUnassigned, uint256 earningsSP) {
    earningsSP = amountFunded == 0
      ? 0
      : earnings.mulDivDown(amountFunded - Math.min(suppliedSP, amountFunded), amountFunded);
    earningsUnassigned = earnings - earningsSP;
  }

  /// @notice adds a maturity date to the borrow or supply positions of the user.
  /// @param encoded encoded maturity dates where the user borrowed or supplied to.
  /// @param maturity the new maturity where the user will borrow or supply to.
  /// @return updated encoded maturity dates.
  function setMaturity(uint256 encoded, uint256 maturity) internal pure returns (uint256) {
    // we initialize the maturity date with also the 1st bit on the 33th position set
    if (encoded == 0) return maturity | (1 << 32);

    uint256 baseMaturity = encoded % (1 << 32);
    if (maturity < baseMaturity) {
      // If the new maturity date is lower than the base, then we need to set it as the new base. We wipe clean the
      // last 32 bits, we shift the amount of INTERVALS and we set the new value with the 33rd bit set
      uint256 range = (baseMaturity - maturity) / TSUtils.INTERVAL;
      if (encoded >> (256 - range) != 0) revert MaturityOverflow();
      encoded = ((encoded >> 32) << (32 + range));
      return maturity | encoded | (1 << 32);
    } else {
      uint256 range = (maturity - baseMaturity) / TSUtils.INTERVAL;
      if (range > 223) revert MaturityOverflow();
      return encoded | (1 << (32 + range));
    }
  }

  /// @notice remove maturity from user's borrow or supplied positions.
  /// @param encoded encoded maturity dates where the user borrowed or supplied to.
  /// @param maturity maturity date to be removed.
  /// @return updated encoded maturity dates.
  function clearMaturity(uint256 encoded, uint256 maturity) internal pure returns (uint256) {
    if (encoded == 0 || encoded == maturity | (1 << 32)) return 0;

    uint256 baseMaturity = encoded % (1 << 32);
    // if the baseMaturity is the one being cleaned
    if (maturity == baseMaturity) {
      // We're wiping 32 bytes + 1 for the old base flag
      uint256 packed = encoded >> 33;
      uint256 range = 1;
      while ((packed & 1) == 0 && packed != 0) {
        unchecked {
          ++range;
        }
        packed >>= 1;
      }
      encoded = ((encoded >> (32 + range)) << 32);
      return (maturity + (range * TSUtils.INTERVAL)) | encoded;
    } else {
      // otherwise just clear the bit
      return encoded & ~(1 << (32 + ((maturity - baseMaturity) / TSUtils.INTERVAL)));
    }
  }

  /// @notice checks if the user has positions in a maturity date.
  /// @param encoded encoded maturity dates where the user borrowed or supplied to.
  /// @param maturity maturity date.
  /// @return true if the user has positions in the maturity date.
  function hasMaturity(uint256 encoded, uint256 maturity) internal pure returns (bool) {
    uint256 baseMaturity = encoded % (1 << 32);
    if (maturity < baseMaturity) return false;

    uint256 range = (maturity - baseMaturity) / TSUtils.INTERVAL;
    if (range > 223) return false;
    return ((encoded >> 32) & (1 << range)) != 0;
  }
}

error InsufficientProtocolLiquidity();
error MaturityOverflow();
