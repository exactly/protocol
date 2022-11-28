// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

library FixedLib {
  using FixedPointMathLib for uint256;

  uint256 internal constant INTERVAL = 4 weeks;

  /// @notice Gets the amount of revenue sharing between the backup supplier and the new fixed pool supplier.
  /// @param pool fixed rate pool.
  /// @param amount amount being provided by the fixed pool supplier.
  /// @param backupFeeRate rate charged to the fixed pool supplier to be accrued by the backup supplier.
  /// @return yield amount to be offered to the fixed pool supplier.
  /// @return backupFee yield to be accrued by the backup supplier for initially providing the liquidity.
  function calculateDeposit(
    Pool memory pool,
    uint256 amount,
    uint256 backupFeeRate
  ) internal pure returns (uint256 yield, uint256 backupFee) {
    uint256 memBackupSupplied = backupSupplied(pool);
    if (memBackupSupplied != 0) {
      yield = pool.unassignedEarnings.mulDivDown(Math.min(amount, memBackupSupplied), memBackupSupplied);
      backupFee = yield.mulWadDown(backupFeeRate);
      yield -= backupFee;
    }
  }

  /// @notice Registers an operation to add supply to a fixed rate pool and potentially reduce backup debt.
  /// @param pool fixed rate pool where an amount will be added to the supply.
  /// @param amount amount to be added to the supply.
  /// @return backupDebtReduction amount that will be reduced from the backup debt.
  function deposit(Pool storage pool, uint256 amount) internal returns (uint256 backupDebtReduction) {
    uint256 borrowed = pool.borrowed;
    uint256 supplied = pool.supplied;
    pool.supplied = supplied + amount;
    backupDebtReduction = Math.min(borrowed - Math.min(borrowed, supplied), amount);
  }

  /// @notice Registers an operation to reduce borrowed amount from a fixed rate pool
  /// and potentially reduce backup debt.
  /// @param pool fixed rate pool where an amount will be repaid.
  /// @param amount amount to be added to the fixed rate pool.
  /// @return backupDebtReduction amount that will be reduced from the backup debt.
  function repay(Pool storage pool, uint256 amount) internal returns (uint256 backupDebtReduction) {
    uint256 borrowed = pool.borrowed;
    uint256 supplied = pool.supplied;
    pool.borrowed = borrowed - amount;
    backupDebtReduction = Math.min(borrowed - Math.min(borrowed, supplied), amount);
  }

  /// @notice Registers an operation to increase borrowed amount of a fixed rate pool
  /// and potentially increase backup debt.
  /// @param pool fixed rate pool where an amount will be borrowed.
  /// @param amount amount to be borrowed from the fixed rate pool.
  /// @return backupDebtAddition amount of new debt that needs to be borrowed from the backup supplier.
  function borrow(Pool storage pool, uint256 amount) internal returns (uint256 backupDebtAddition) {
    uint256 borrowed = pool.borrowed;
    uint256 newBorrowed = borrowed + amount;

    backupDebtAddition = newBorrowed - Math.min(Math.max(borrowed, pool.supplied), newBorrowed);
    pool.borrowed = newBorrowed;
  }

  /// @notice Registers an operation to reduce supply from a fixed rate pool and potentially increase backup debt.
  /// @param pool fixed rate pool where amount will be withdrawn.
  /// @param amountToDiscount amount to be withdrawn from the fixed rate pool.
  /// @return backupDebtAddition amount of new debt that needs to be borrowed from the backup supplier.
  function withdraw(Pool storage pool, uint256 amountToDiscount) internal returns (uint256 backupDebtAddition) {
    uint256 borrowed = pool.borrowed;
    uint256 supplied = pool.supplied;
    uint256 newSupply = supplied - amountToDiscount;

    backupDebtAddition = Math.min(supplied, borrowed) - Math.min(newSupply, borrowed);
    pool.supplied = newSupply;
  }

  /// @notice Accrues backup earnings from `unassignedEarnings` based on the `lastAccrual` time.
  /// @param pool fixed rate pool where earnings will be accrued.
  /// @param maturity maturity date of the pool.
  /// @return backupEarnings amount of earnings to be distributed to the backup supplier.
  function accrueEarnings(Pool storage pool, uint256 maturity) internal returns (uint256 backupEarnings) {
    uint256 lastAccrual = pool.lastAccrual;

    if (block.timestamp < maturity) {
      uint256 unassignedEarnings = pool.unassignedEarnings;
      pool.lastAccrual = block.timestamp;
      backupEarnings = unassignedEarnings.mulDivDown(block.timestamp - lastAccrual, maturity - lastAccrual);
      pool.unassignedEarnings = unassignedEarnings - backupEarnings;
    } else if (lastAccrual == maturity) {
      backupEarnings = 0;
    } else {
      pool.lastAccrual = maturity;
      backupEarnings = pool.unassignedEarnings;
      pool.unassignedEarnings = 0;
    }
  }

  /// @notice Calculates the amount that a fixed rate pool borrowed from the backup supplier.
  /// @param pool fixed rate pool.
  /// @return amount borrowed from the fixed rate pool.
  function backupSupplied(Pool memory pool) internal pure returns (uint256) {
    uint256 borrowed = pool.borrowed;
    uint256 supplied = pool.supplied;
    return borrowed - Math.min(borrowed, supplied);
  }

  /// @notice Modify positions based on a certain amount, keeping the original principal/fee ratio.
  /// @dev modifies the original struct and returns it. Needs for the amount to be less than the principal and the fee
  /// @param position original position to be scaled.
  /// @param amount to be used as a full value (principal + interest).
  /// @return scaled position.
  function scaleProportionally(Position memory position, uint256 amount) internal pure returns (Position memory) {
    uint256 principal = amount.mulDivDown(position.principal, position.principal + position.fee);
    position.principal = principal;
    position.fee = amount - principal;
    return position;
  }

  /// @notice Reduce positions based on a certain amount, keeping the original principal/fee ratio.
  /// @dev modifies the original struct and returns it.
  /// @param position original position to be reduced.
  /// @param amount to be used as a full value (principal + interest).
  /// @return reduced position.
  function reduceProportionally(Position memory position, uint256 amount) internal pure returns (Position memory) {
    uint256 positionAssets = position.principal + position.fee;
    uint256 newPositionAssets = positionAssets - amount;
    position.principal = newPositionAssets.mulDivDown(position.principal, positionAssets);
    position.fee = newPositionAssets - position.principal;
    return position;
  }

  /// @notice Calculates what proportion of earnings would `borrowAmount` represent considering `backupSupplied`.
  /// @param earnings amount to be distributed.
  /// @param borrowAmount amount that will be checked if came from the backup supplier or fixed rate pool.
  /// @return unassignedEarnings earnings to be added to `unassignedEarnings`.
  /// @return backupEarnings earnings to be distributed to the backup supplier.
  function distributeEarnings(
    Pool memory pool,
    uint256 earnings,
    uint256 borrowAmount
  ) internal pure returns (uint256 unassignedEarnings, uint256 backupEarnings) {
    backupEarnings = borrowAmount == 0
      ? 0
      : earnings.mulDivDown(borrowAmount - Math.min(backupSupplied(pool), borrowAmount), borrowAmount);
    unassignedEarnings = earnings - backupEarnings;
  }

  /// @notice Adds a maturity date to the borrow or supply positions of the account.
  /// @param encoded encoded maturity dates where the account borrowed or supplied to.
  /// @param maturity the new maturity where the account will borrow or supply to.
  /// @return updated encoded maturity dates.
  function setMaturity(uint256 encoded, uint256 maturity) internal pure returns (uint256) {
    // initialize the maturity with also the 1st bit on the 33th position set
    if (encoded == 0) return maturity | (1 << 32);

    uint256 baseMaturity = encoded & ((1 << 32) - 1);
    if (maturity < baseMaturity) {
      // if the new maturity is lower than the base, set it as the new base
      // wipe clean the last 32 bits, shift the amount of `INTERVAL` and set the new value with the 33rd bit set
      uint256 range = (baseMaturity - maturity) / INTERVAL;
      if (encoded >> (256 - range) != 0) revert MaturityOverflow();
      encoded = ((encoded >> 32) << (32 + range));
      return maturity | encoded | (1 << 32);
    } else {
      uint256 range = (maturity - baseMaturity) / INTERVAL;
      if (range > 223) revert MaturityOverflow();
      return encoded | (1 << (32 + range));
    }
  }

  /// @notice Remove maturity from account's borrow or supplied positions.
  /// @param encoded encoded maturity dates where the account borrowed or supplied to.
  /// @param maturity maturity date to be removed.
  /// @return updated encoded maturity dates.
  function clearMaturity(uint256 encoded, uint256 maturity) internal pure returns (uint256) {
    if (encoded == 0 || encoded == maturity | (1 << 32)) return 0;

    uint256 baseMaturity = encoded & ((1 << 32) - 1);
    // if the baseMaturity is the one being cleaned
    if (maturity == baseMaturity) {
      // wipe 32 bytes + 1 for the old base flag
      uint256 packed = encoded >> 33;
      uint256 range = 1;
      while ((packed & 1) == 0 && packed != 0) {
        unchecked {
          ++range;
        }
        packed >>= 1;
      }
      encoded = ((encoded >> (32 + range)) << 32);
      return (maturity + (range * INTERVAL)) | encoded;
    } else {
      // otherwise just clear the bit
      return encoded & ~(1 << (32 + ((maturity - baseMaturity) / INTERVAL)));
    }
  }

  /// @notice Verifies that a maturity is `VALID`, `MATURED`, `NOT_READY` or `INVALID`.
  /// @dev if expected state doesn't match the calculated one, it reverts with a custom error `UnmatchedPoolState`.
  /// @param maturity timestamp of the maturity date to be verified.
  /// @param maxPools number of pools available in the time horizon.
  /// @param requiredState state required by the caller to be verified (see `State` for description).
  /// @param alternativeState state required by the caller to be verified (see `State` for description).
  function checkPoolState(uint256 maturity, uint8 maxPools, State requiredState, State alternativeState) internal view {
    State state;
    if (maturity % INTERVAL != 0) {
      state = State.INVALID;
    } else if (maturity <= block.timestamp) {
      state = State.MATURED;
    } else if (maturity > block.timestamp - (block.timestamp % INTERVAL) + (INTERVAL * maxPools)) {
      state = State.NOT_READY;
    } else {
      state = State.VALID;
    }

    if (state != requiredState && state != alternativeState) {
      if (alternativeState == State.NONE) revert UnmatchedPoolState(uint8(state), uint8(requiredState));

      revert UnmatchedPoolStates(uint8(state), uint8(requiredState), uint8(alternativeState));
    }
  }

  /// @notice Stores the accountability of a fixed interest rate pool.
  /// @param borrowed total amount borrowed from the pool.
  /// @param supplied total amount supplied to the pool.
  /// @param unassignedEarnings total amount of earnings not yet distributed and accrued.
  /// @param lastAccrual timestamp for the last time that some earnings have been distributed to the backup supplier.
  struct Pool {
    uint256 borrowed;
    uint256 supplied;
    uint256 unassignedEarnings;
    uint256 lastAccrual;
  }

  /// @notice Stores principal and fee of a borrow or a supply position of a account in a fixed rate pool.
  /// @param principal amount borrowed or supplied to the fixed rate pool.
  /// @param fee amount of fees to be repaid or earned at the maturity of the fixed rate pool.
  struct Position {
    uint256 principal;
    uint256 fee;
  }

  enum State {
    NONE,
    INVALID,
    MATURED,
    VALID,
    NOT_READY
  }
}

error MaturityOverflow();
error UnmatchedPoolState(uint8 state, uint8 requiredState);
error UnmatchedPoolStates(uint8 state, uint8 requiredState, uint8 alternativeState);
