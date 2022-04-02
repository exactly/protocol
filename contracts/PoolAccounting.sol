// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "@rari-capital/solmate-v6/src/utils/FixedPointMathLib.sol";
import { IInterestRateModel } from "./interfaces/IInterestRateModel.sol";
import { TSUtils } from "./utils/TSUtils.sol";
import { PoolLib } from "./utils/PoolLib.sol";

contract PoolAccounting is AccessControl {
  using PoolLib for PoolLib.MaturityPool;
  using PoolLib for PoolLib.Position;
  using PoolLib for uint256;
  using FixedPointMathLib for uint256;

  // Vars used in `borrowMP` to avoid stack too deep problem
  struct BorrowVars {
    PoolLib.Position position;
    uint256 fee;
    uint256 newUnassignedEarnings;
    uint256 earningsSP;
  }

  // Vars used in `repayMP` to avoid stack too deep problem
  struct RepayVars {
    PoolLib.Position position;
    PoolLib.Position scaleDebtCovered;
    uint256 amountOwed;
    uint256 penalties;
    uint256 discountFee;
    uint256 feeSP;
    uint256 amountStillBorrowed;
  }

  mapping(uint256 => mapping(address => PoolLib.Position)) public mpUserSuppliedAmount;
  mapping(uint256 => mapping(address => PoolLib.Position)) public mpUserBorrowedAmount;

  mapping(address => uint256) public userMpBorrowed;
  mapping(uint256 => PoolLib.MaturityPool) public maturityPools;
  uint256 public smartPoolBorrowed;
  uint256 public smartPoolEarningsAccumulator;

  IInterestRateModel public interestRateModel;

  uint256 public penaltyRate;
  uint256 public smartPoolReserveFactor;

  /// @notice emitted when the interestRateModel is changed by admin.
  /// @param newInterestRateModel new interest rate model to be used by this PoolAccounting.
  event InterestRateModelUpdated(IInterestRateModel newInterestRateModel);

  /// @notice emitted when the penaltyRate is changed by admin.
  /// @param newPenaltyRate penaltyRate percentage per second represented with 1e18 decimals.
  event PenaltyRateUpdated(uint256 newPenaltyRate);

  /// @notice emitted when the smartPoolReserveFactor is changed by admin.
  /// @param newSmartPoolReserveFactor smartPoolReserveFactor percentage.
  event SmartPoolReserveFactorUpdated(uint256 newSmartPoolReserveFactor);

  constructor(
    IInterestRateModel _interestRateModel,
    uint256 _penaltyRate,
    uint256 _smartPoolReserveFactor
  ) {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    interestRateModel = _interestRateModel;

    penaltyRate = _penaltyRate;
    smartPoolReserveFactor = _smartPoolReserveFactor;
  }

  /// @notice Sets the interest rate model to be used by this PoolAccounting.
  /// @param _interestRateModel new interest rate model.
  function setInterestRateModel(IInterestRateModel _interestRateModel) external onlyRole(DEFAULT_ADMIN_ROLE) {
    interestRateModel = _interestRateModel;
    emit InterestRateModelUpdated(_interestRateModel);
  }

  /// @notice Sets the penalty rate per second.
  /// @param _penaltyRate percentage represented with 18 decimals.
  function setPenaltyRate(uint256 _penaltyRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
    penaltyRate = _penaltyRate;
    emit PenaltyRateUpdated(_penaltyRate);
  }

  /// @notice Sets the percentage that represents the smart pool liquidity reserves that can't be borrowed.
  /// @param _smartPoolReserveFactor parameter represented with 18 decimals.
  function setSmartPoolReserveFactor(uint256 _smartPoolReserveFactor) external onlyRole(DEFAULT_ADMIN_ROLE) {
    smartPoolReserveFactor = _smartPoolReserveFactor;
    emit SmartPoolReserveFactorUpdated(_smartPoolReserveFactor);
  }

  /// @dev Function to account for borrowing money from a maturity pool (MP). It doesn't check liquidity for the
  /// borrower, so the `fixedLender` should call `validateBorrowMP` immediately after calling this function.
  /// @param maturity maturity date / pool id where the asset will be borrowed.
  /// @param borrower borrower that it will take the debt.
  /// @param amount amount that the borrower will be borrowing.
  /// @param maxAmountAllowed maximum amount that the borrower is willing to pay at maturity.
  /// @param smartPoolTotalSupply total supply in the smart pool.
  /// @return totalOwedNewBorrow : total amount that will need to be paid at maturity for this borrow.
  function borrowMP(
    uint256 maturity,
    address borrower,
    uint256 amount,
    uint256 maxAmountAllowed,
    uint256 smartPoolTotalSupply
  ) internal returns (uint256 totalOwedNewBorrow, uint256 earningsSP) {
    BorrowVars memory borrowVars;
    PoolLib.MaturityPool storage pool = maturityPools[maturity];

    earningsSP += pool.accrueEarnings(maturity, block.timestamp);

    borrowVars.fee = amount.fmul(
      interestRateModel.getRateToBorrow(
        maturity,
        block.timestamp,
        amount,
        pool.borrowed,
        pool.supplied,
        smartPoolTotalSupply
      ),
      1e18
    );
    totalOwedNewBorrow = amount + borrowVars.fee;

    smartPoolBorrowed += pool.borrowMoney(amount, smartPoolTotalSupply - smartPoolBorrowed);
    if (smartPoolBorrowed > smartPoolTotalSupply.fmul(1e18 - smartPoolReserveFactor, 1e18))
      revert SmartPoolReserveExceeded();
    // We validate that the user is not taking arbitrary fees
    if (totalOwedNewBorrow > maxAmountAllowed) revert TooMuchSlippage();

    // If user doesn't have a current position, we add it to the list
    // of all of them
    borrowVars.position = mpUserBorrowedAmount[maturity][borrower];
    if (borrowVars.position.principal == 0) {
      userMpBorrowed[borrower] = userMpBorrowed[borrower].setMaturity(maturity);
    }

    // We calculate what portion of the fees are to be accrued and what portion goes to earnings accumulator
    (borrowVars.newUnassignedEarnings, borrowVars.earningsSP) = PoolLib.distributeEarningsAccordingly(
      borrowVars.fee,
      pool.suppliedSP,
      amount
    );
    smartPoolEarningsAccumulator += borrowVars.earningsSP;
    pool.earningsUnassigned += borrowVars.newUnassignedEarnings;

    mpUserBorrowedAmount[maturity][borrower] = PoolLib.Position(
      borrowVars.position.principal + amount,
      borrowVars.position.fee + borrowVars.fee
    );
  }

  /// @dev Function to account for a deposit to a maturity pool (MP). It doesn't transfer or.
  /// @param maturity maturity date / pool id where the asset will be deposited.
  /// @param supplier address that will be depositing the assets.
  /// @param amount amount that the supplier will be depositing.
  /// @param minAmountRequired minimum amount that the borrower is expecting to receive at maturity.
  /// @return currentTotalDeposit : the amount that should be collected at maturity for this deposit.
  function depositMP(
    uint256 maturity,
    address supplier,
    uint256 amount,
    uint256 minAmountRequired
  ) internal returns (uint256 currentTotalDeposit, uint256 earningsSP) {
    PoolLib.MaturityPool storage pool = maturityPools[maturity];
    earningsSP = pool.accrueEarnings(maturity, block.timestamp);

    (uint256 fee, uint256 feeSP) = interestRateModel.getYieldForDeposit(
      pool.suppliedSP,
      pool.earningsUnassigned,
      amount
    );

    currentTotalDeposit = amount + fee;
    if (currentTotalDeposit < minAmountRequired) revert TooMuchSlippage();

    smartPoolBorrowed -= pool.depositMoney(amount);
    pool.earningsUnassigned -= fee + feeSP;
    smartPoolEarningsAccumulator += feeSP;

    // We update users's position
    PoolLib.Position memory position = mpUserSuppliedAmount[maturity][supplier];
    mpUserSuppliedAmount[maturity][supplier] = PoolLib.Position(position.principal + amount, position.fee + fee);
  }

  /// @dev Function to account for a withdraw from a maturity pool (MP).
  /// @param maturity maturity date / pool id where the asset should be accounted for.
  /// @param redeemer address that should have the assets withdrawn.
  /// @param amount amount that the redeemer will be extracting.
  /// @param smartPoolTotalSupply total supply in the smart pool.
  function withdrawMP(
    uint256 maturity,
    address redeemer,
    uint256 amount,
    uint256 minAmountRequired,
    uint256 smartPoolTotalSupply
  ) internal returns (uint256 redeemAmountDiscounted, uint256 earningsSP) {
    PoolLib.MaturityPool storage pool = maturityPools[maturity];

    earningsSP = pool.accrueEarnings(maturity, block.timestamp);

    PoolLib.Position memory position = mpUserSuppliedAmount[maturity][redeemer];

    if (amount > position.principal + position.fee) amount = position.principal + position.fee;

    // We verify if there are any penalties/fee for him because of
    // early withdrawal - if so: discount
    if (block.timestamp < maturity) {
      redeemAmountDiscounted = amount.fdiv(
        1e18 +
          interestRateModel.getRateToBorrow(
            maturity,
            block.timestamp,
            amount,
            pool.borrowed,
            pool.supplied,
            smartPoolTotalSupply
          ),
        1e18
      );
    } else {
      redeemAmountDiscounted = amount;
    }

    if (redeemAmountDiscounted < minAmountRequired) revert TooMuchSlippage();

    // We remove the supply from the offer
    smartPoolBorrowed += pool.withdrawMoney(
      PoolLib.Position(position.principal, position.fee).scaleProportionally(amount).principal,
      smartPoolTotalSupply - smartPoolBorrowed
    );

    // All the fees go to unassigned or to the smart pool
    (uint256 earningsUnassigned, uint256 newEarningsSP) = PoolLib.distributeEarningsAccordingly(
      amount - redeemAmountDiscounted,
      pool.suppliedSP,
      redeemAmountDiscounted
    );
    pool.earningsUnassigned += earningsUnassigned;
    earningsSP += newEarningsSP;

    // the user gets discounted the full amount
    mpUserSuppliedAmount[maturity][redeemer] = position.reduceProportionally(amount);
  }

  /// @dev Function to account for a repayment to a maturity pool (MP).
  /// @param maturity maturity date / pool id where the asset should be accounted for.
  /// @param borrower address where the debt will be reduced.
  /// @param repayAmount amount that it will be repaid in the MP.
  /// @return actualRepayAmount the amount with discounts included that will finally be transferred.
  /// @return debtCovered the sum of principal and fees that this repayment covers.
  /// @return earningsSP amount of earnings to be accrued by the smart pool depositors.
  function repayMP(
    uint256 maturity,
    address borrower,
    uint256 repayAmount,
    uint256 maxAmountAllowed
  )
    internal
    returns (
      uint256 actualRepayAmount,
      uint256 debtCovered,
      uint256 earningsSP
    )
  {
    RepayVars memory repayVars;

    PoolLib.MaturityPool storage pool = maturityPools[maturity];

    // SP supply needs to accrue its interests
    earningsSP = pool.accrueEarnings(maturity, block.timestamp);

    // Amount Owed is (principal+fees)*penalties
    repayVars.amountOwed = getAccountDebt(borrower, maturity);
    repayVars.position = mpUserBorrowedAmount[maturity][borrower];

    if (repayAmount > repayVars.amountOwed) repayAmount = repayVars.amountOwed;

    // We calculate the amount of the debt this covers, paying proportionally
    // the amount of interests on the overdue debt. If repay amount = amount owed,
    // then amountBorrowed is what should be discounted to the users account
    // Math.min to not go over repayAmount since we return exceeding money, but
    // hasn't been calculated yet
    debtCovered = repayAmount.fmul(repayVars.position.principal + repayVars.position.fee, repayVars.amountOwed);
    repayVars.scaleDebtCovered = PoolLib
      .Position(repayVars.position.principal, repayVars.position.fee)
      .scaleProportionally(debtCovered);

    // Early repayment allows you to get a discount from the unassigned earnings
    if (block.timestamp < maturity) {
      // We calculate the deposit fee considering the amount
      // of debt he'll pay
      (repayVars.discountFee, repayVars.feeSP) = interestRateModel.getYieldForDeposit(
        pool.suppliedSP,
        pool.earningsUnassigned,
        repayVars.scaleDebtCovered.principal
        // ^ this case shouldn't contain penalties since is before maturity date
      );

      earningsSP += repayVars.feeSP;

      // We verify that the user agrees to this discount
      if (debtCovered > repayVars.discountFee + maxAmountAllowed) revert TooMuchSlippage();

      // We remove the fee from unassigned earnings
      pool.earningsUnassigned -= repayVars.discountFee + repayVars.feeSP;
    } else {
      // All penalties go to the smart pool accumulator
      smartPoolEarningsAccumulator +=
        repayAmount -
        (repayVars.scaleDebtCovered.principal + repayVars.scaleDebtCovered.fee);
    }
    // user paid more than it should. The fee gets discounted from the user
    // through _actualRepayAmount_ and on the pool side it was removed from
    // the unassignedEarnings a few lines before ^
    actualRepayAmount = repayAmount - repayVars.discountFee;

    // We reduce the borrowed and we might decrease the SP debt
    smartPoolBorrowed -= pool.repayMoney(repayVars.scaleDebtCovered.principal);

    //
    // From now on: We update the user position
    //
    repayVars.position.reduceProportionally(debtCovered);
    if (repayVars.position.principal + repayVars.position.fee == 0) {
      delete mpUserBorrowedAmount[maturity][borrower];
      userMpBorrowed[borrower] = userMpBorrowed[borrower].clearMaturity(maturity);
    } else {
      // we proportionally reduce the values
      mpUserBorrowedAmount[maturity][borrower] = repayVars.position;
    }
  }

  /// @dev Gets all borrows for a wallet in certain maturity (or MATURITY_ALL).
  /// @param who wallet to return status snapshot in the specified maturity date.
  /// @param maturity maturity where the borrow is taking place. MATURITY_ALL returns all borrows.
  /// @return debt the amount the user deposited to the smart pool and the total money he owes from maturities.
  function getAccountBorrows(address who, uint256 maturity) public view returns (uint256 debt) {
    if (maturity == PoolLib.MATURITY_ALL) {
      uint256 encodedMaturities = userMpBorrowed[who];
      uint32 baseMaturity = uint32(encodedMaturities % (1 << 32));
      uint224 packedMaturities = uint224(encodedMaturities >> 32);
      // We calculate all the timestamps using the baseMaturity
      // and the following bits representing the following weeks
      for (uint224 i = 0; i < 224; ) {
        if ((packedMaturities & (1 << i)) != 0) {
          debt += getAccountDebt(who, baseMaturity + (i * TSUtils.INTERVAL));
        }
        unchecked {
          ++i;
        }
        if ((1 << i) > packedMaturities) break;
      }
    } else debt = getAccountDebt(who, maturity);
  }

  /// @notice Internal function to get the debt + penalties of an account for a certain maturity.
  /// @param who wallet to return debt status for the specified maturity.
  /// @param maturity amount to be transfered.
  /// @return totalDebt : the total debt denominated in number of tokens.
  function getAccountDebt(address who, uint256 maturity) internal view returns (uint256 totalDebt) {
    PoolLib.Position memory position = mpUserBorrowedAmount[maturity][who];
    totalDebt = position.principal + position.fee;
    uint256 secondsDelayed = TSUtils.secondsPre(maturity, block.timestamp);
    if (secondsDelayed > 0) totalDebt += totalDebt.fmul(secondsDelayed * penaltyRate, 1e18);
  }
}

error AlreadyInitialized();
error TooMuchSlippage();
error SmartPoolReserveExceeded();
