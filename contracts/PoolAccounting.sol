// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { InterestRateModel } from "./InterestRateModel.sol";
import { InvalidParameter } from "./Auditor.sol";
import { TSUtils } from "./utils/TSUtils.sol";
import { PoolLib } from "./utils/PoolLib.sol";

contract PoolAccounting is AccessControl {
  using PoolLib for PoolLib.MaturityPool;
  using PoolLib for PoolLib.Position;
  using PoolLib for uint256;
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;

  // Vars used in `borrowMP` to avoid stack too deep problem
  struct BorrowVars {
    PoolLib.Position position;
    uint256 fee;
    uint256 newUnassignedEarnings;
    uint256 earningsSP;
  }

  struct DampSpeed {
    uint256 up;
    uint256 down;
  }

  mapping(uint256 => mapping(address => PoolLib.Position)) public mpUserSuppliedAmount;
  mapping(uint256 => mapping(address => PoolLib.Position)) public mpUserBorrowedAmount;

  mapping(address => uint256) public userMpBorrowed;
  mapping(address => uint256) public userMpSupplied;
  mapping(uint256 => PoolLib.MaturityPool) public maturityPools;
  uint256 public smartPoolBorrowed;
  uint256 public smartPoolEarningsAccumulator;
  uint256 public lastAverageUpdate;
  uint256 public smartPoolAssetsAverage;

  InterestRateModel public interestRateModel;

  uint256 public penaltyRate;
  uint256 public smartPoolReserveFactor;
  uint256 public dampSpeedUp;
  uint256 public dampSpeedDown;

  /// @notice emitted when the interestRateModel is changed by admin.
  /// @param newInterestRateModel new interest rate model to be used by this PoolAccounting.
  event InterestRateModelUpdated(InterestRateModel indexed newInterestRateModel);

  /// @notice emitted when the penaltyRate is changed by admin.
  /// @param newPenaltyRate penaltyRate percentage per second represented with 1e18 decimals.
  event PenaltyRateUpdated(uint256 newPenaltyRate);

  /// @notice emitted when the smartPoolReserveFactor is changed by admin.
  /// @param newSmartPoolReserveFactor smartPoolReserveFactor percentage.
  event SmartPoolReserveFactorUpdated(uint256 newSmartPoolReserveFactor);

  /// @notice emitted when the damp speeds are changed by admin.
  /// @param newDampSpeedUp represented with 1e18 decimals.
  /// @param newDampSpeedDown represented with 1e18 decimals.
  event DampSpeedUpdated(uint256 newDampSpeedUp, uint256 newDampSpeedDown);

  constructor(
    InterestRateModel interestRateModel_,
    uint256 penaltyRate_,
    uint256 smartPoolReserveFactor_,
    DampSpeed memory dampSpeed
  ) {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    interestRateModel = interestRateModel_;

    penaltyRate = penaltyRate_;
    smartPoolReserveFactor = smartPoolReserveFactor_;
    dampSpeedUp = dampSpeed.up;
    dampSpeedDown = dampSpeed.down;
  }

  /// @notice Sets the interest rate model to be used by this PoolAccounting.
  /// @param _interestRateModel new interest rate model.
  function setInterestRateModel(InterestRateModel _interestRateModel) external onlyRole(DEFAULT_ADMIN_ROLE) {
    interestRateModel = _interestRateModel;
    emit InterestRateModelUpdated(_interestRateModel);
  }

  /// @notice Sets the penalty rate per second.
  /// @dev Value can only be set approximately between 5% and 1% daily.
  /// @param _penaltyRate percentage represented with 18 decimals.
  function setPenaltyRate(uint256 _penaltyRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_penaltyRate > 5.79e11 || _penaltyRate < 1.15e11) revert InvalidParameter();
    penaltyRate = _penaltyRate;
    emit PenaltyRateUpdated(_penaltyRate);
  }

  /// @notice Sets the percentage that represents the smart pool liquidity reserves that can't be borrowed.
  /// @dev Value can only be set between 20% and 0%.
  /// @param _smartPoolReserveFactor parameter represented with 18 decimals.
  function setSmartPoolReserveFactor(uint256 _smartPoolReserveFactor) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_smartPoolReserveFactor > 0.2e18) revert InvalidParameter();
    smartPoolReserveFactor = _smartPoolReserveFactor;
    emit SmartPoolReserveFactorUpdated(_smartPoolReserveFactor);
  }

  /// @notice Sets the damp speed used to update the smartPoolAssetsAverage.
  /// @dev Values can only be set between 0 and 100%.
  /// @param dampSpeed represented with 18 decimals.
  function setDampSpeed(DampSpeed memory dampSpeed) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (dampSpeed.up > 1e18 || dampSpeed.down > 1e18) revert InvalidParameter();
    dampSpeedUp = dampSpeed.up;
    dampSpeedDown = dampSpeed.down;
    emit DampSpeedUpdated(dampSpeed.up, dampSpeed.down);
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

    earningsSP = pool.accrueEarnings(maturity, block.timestamp);

    updateSmartPoolAssetsAverage(smartPoolTotalSupply);
    borrowVars.fee = amount.mulWadDown(
      interestRateModel.getRateToBorrow(
        maturity,
        block.timestamp,
        amount,
        pool.borrowed,
        pool.supplied,
        smartPoolAssetsAverage
      )
    );
    totalOwedNewBorrow = amount + borrowVars.fee;

    smartPoolBorrowed += pool.borrowMoney(amount, smartPoolTotalSupply - smartPoolBorrowed);
    if (smartPoolBorrowed > smartPoolTotalSupply.mulWadDown(1e18 - smartPoolReserveFactor))
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
      pool.smartPoolBorrowed(),
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
      pool.smartPoolBorrowed(),
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

    // If user doesn't have a current position, we add it to the list
    // of all of them
    if (position.principal == 0) {
      userMpSupplied[supplier] = userMpSupplied[supplier].setMaturity(maturity);
    }

    mpUserSuppliedAmount[maturity][supplier] = PoolLib.Position(position.principal + amount, position.fee + fee);
  }

  /// @dev Function to account for a withdraw from a maturity pool (MP).
  /// @param maturity maturity date / pool id where the asset should be accounted for.
  /// @param redeemer address that should have the assets withdrawn.
  /// @param positionAssets amount that the redeemer will be extracting from his position.
  /// @param smartPoolTotalSupply total supply in the smart pool.
  function withdrawMP(
    uint256 maturity,
    address redeemer,
    uint256 positionAssets,
    uint256 minAmountRequired,
    uint256 smartPoolTotalSupply
  ) internal returns (uint256 redeemAmountDiscounted, uint256 earningsSP) {
    PoolLib.MaturityPool storage pool = maturityPools[maturity];

    earningsSP = pool.accrueEarnings(maturity, block.timestamp);

    PoolLib.Position memory position = mpUserSuppliedAmount[maturity][redeemer];

    if (positionAssets > position.principal + position.fee) positionAssets = position.principal + position.fee;

    // We verify if there are any penalties/fee for him because of
    // early withdrawal - if so: discount
    if (block.timestamp < maturity) {
      updateSmartPoolAssetsAverage(smartPoolTotalSupply);
      redeemAmountDiscounted = positionAssets.divWadDown(
        1e18 +
          interestRateModel.getRateToBorrow(
            maturity,
            block.timestamp,
            positionAssets,
            pool.borrowed,
            pool.supplied,
            smartPoolAssetsAverage
          )
      );
    } else {
      redeemAmountDiscounted = positionAssets;
    }

    if (redeemAmountDiscounted < minAmountRequired) revert TooMuchSlippage();

    // We remove the supply from the offer
    smartPoolBorrowed += pool.withdrawMoney(
      PoolLib.Position(position.principal, position.fee).scaleProportionally(positionAssets).principal,
      smartPoolTotalSupply - smartPoolBorrowed
    );

    // All the fees go to unassigned or to the smart pool
    (uint256 earningsUnassigned, uint256 newEarningsSP) = PoolLib.distributeEarningsAccordingly(
      positionAssets - redeemAmountDiscounted,
      pool.smartPoolBorrowed(),
      redeemAmountDiscounted
    );
    pool.earningsUnassigned += earningsUnassigned;
    earningsSP += newEarningsSP;

    // the user gets discounted the full amount
    position.reduceProportionally(positionAssets);
    if (position.principal + position.fee == 0) {
      delete mpUserSuppliedAmount[maturity][redeemer];
      userMpSupplied[redeemer] = userMpSupplied[redeemer].clearMaturity(maturity);
    } else {
      // we proportionally reduce the values
      mpUserSuppliedAmount[maturity][redeemer] = position;
    }
  }

  /// @dev Function to account for a repayment to a maturity pool (MP).
  /// @param maturity maturity date / pool id where the asset should be accounted for.
  /// @param borrower address where the debt will be reduced.
  /// @param positionAssets the sum of principal and fees that this repayment covers.
  /// @return repayAmount the amount with discounts included that will finally be transferred.
  /// @return debtCovered the sum of principal and fees that this repayment covers.
  /// @return earningsSP amount of earnings to be accrued by the smart pool depositors.
  function repayMP(
    uint256 maturity,
    address borrower,
    uint256 positionAssets,
    uint256 maxAmountAllowed
  )
    internal
    returns (
      uint256 repayAmount,
      uint256 debtCovered,
      uint256 earningsSP
    )
  {
    PoolLib.MaturityPool storage pool = maturityPools[maturity];

    // SP supply needs to accrue its interests
    earningsSP = pool.accrueEarnings(maturity, block.timestamp);

    PoolLib.Position memory position = mpUserBorrowedAmount[maturity][borrower];

    debtCovered = Math.min(positionAssets, position.principal + position.fee);

    PoolLib.Position memory scaleDebtCovered = PoolLib.Position(position.principal, position.fee).scaleProportionally(
      debtCovered
    );

    // Early repayment allows you to get a discount from the unassigned earnings
    if (block.timestamp < maturity) {
      // We calculate the deposit fee considering the amount of debt he'll pay
      (uint256 discountFee, uint256 feeSP) = interestRateModel.getYieldForDeposit(
        pool.smartPoolBorrowed(),
        pool.earningsUnassigned,
        scaleDebtCovered.principal
        // ^ this case shouldn't contain penalties since is before maturity date
      );

      earningsSP += feeSP;

      // We remove the fee from unassigned earnings
      pool.earningsUnassigned -= discountFee + feeSP;

      // The fee gets discounted from the user through `repayAmount`
      repayAmount = debtCovered - discountFee;
    } else {
      repayAmount = debtCovered + debtCovered.mulWadDown((block.timestamp - maturity) * penaltyRate);

      // All penalties go to the smart pool accumulator
      smartPoolEarningsAccumulator += repayAmount - debtCovered;
    }

    // We verify that the user agrees to this discount or penalty
    if (repayAmount > maxAmountAllowed) revert TooMuchSlippage();

    // We reduce the borrowed and we might decrease the SP debt
    smartPoolBorrowed -= pool.repayMoney(scaleDebtCovered.principal);

    //
    // From now on: We update the user position
    //
    position.reduceProportionally(debtCovered);
    if (position.principal + position.fee == 0) {
      delete mpUserBorrowedAmount[maturity][borrower];
      userMpBorrowed[borrower] = userMpBorrowed[borrower].clearMaturity(maturity);
    } else {
      // we proportionally reduce the values
      mpUserBorrowedAmount[maturity][borrower] = position;
    }
  }

  /// @dev Gets all borrows for a wallet in certain maturity (or MATURITY_ALL).
  /// @param who wallet to return status snapshot in the specified maturity date.
  /// @param maturity maturity where the borrow is taking place. MATURITY_ALL returns all borrows.
  /// @return sumPositions the total amount of borrows in user position.
  /// @return sumPenalties the total penalties for late repayment in all maturities.
  function getAccountBorrows(address who, uint256 maturity)
    public
    view
    returns (uint256 sumPositions, uint256 sumPenalties)
  {
    if (maturity == PoolLib.MATURITY_ALL) {
      uint256 encodedMaturities = userMpBorrowed[who];
      uint256 baseMaturity = encodedMaturities % (1 << 32);
      uint256 packedMaturities = encodedMaturities >> 32;
      // We calculate all the timestamps using the baseMaturity and the following bits representing the following weeks
      for (uint256 i = 0; i < 224; ) {
        if ((packedMaturities & (1 << i)) != 0) {
          (uint256 position, uint256 penalties) = getAccountDebt(who, baseMaturity + (i * TSUtils.INTERVAL));
          sumPositions += position;
          sumPenalties += penalties;
        }
        unchecked {
          ++i;
        }
        if ((1 << i) > packedMaturities) break;
      }
    } else (sumPositions, sumPenalties) = getAccountDebt(who, maturity);
  }

  /// @notice Internal function to get the debt + penalties of an account for a certain maturity.
  /// @param who wallet to return debt status for the specified maturity.
  /// @param maturity amount to be transferred.
  /// @return position the position debt denominated in number of tokens.
  /// @return penalties the penalties for late repayment.
  function getAccountDebt(address who, uint256 maturity) internal view returns (uint256 position, uint256 penalties) {
    PoolLib.Position memory data = mpUserBorrowedAmount[maturity][who];
    position = data.principal + data.fee;
    uint256 secondsDelayed = TSUtils.secondsPre(maturity, block.timestamp);
    if (secondsDelayed > 0) penalties = position.mulWadDown(secondsDelayed * penaltyRate);
  }

  /// @notice Updates the smartPoolAssetsAverage.
  /// @param smartPoolAssets smart pool total assets.
  function updateSmartPoolAssetsAverage(uint256 smartPoolAssets) internal {
    uint256 dampSpeedFactor = smartPoolAssets < smartPoolAssetsAverage ? dampSpeedDown : dampSpeedUp;
    uint256 averageFactor = uint256(
      1e18 - (-int256(dampSpeedFactor * (block.timestamp - lastAverageUpdate))).expWadDown()
    );
    smartPoolAssetsAverage =
      smartPoolAssetsAverage.mulWadDown(1e18 - averageFactor) +
      averageFactor.mulWadDown(smartPoolAssets);
    lastAverageUpdate = block.timestamp;
  }
}

error AlreadyInitialized();
error TooMuchSlippage();
error SmartPoolReserveExceeded();
