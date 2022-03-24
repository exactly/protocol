// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { IPoolAccounting, AlreadyInitialized, TooMuchSlippage } from "./interfaces/IPoolAccounting.sol";
import { IFixedLender, NotFixedLender } from "./interfaces/IFixedLender.sol";
import { IInterestRateModel } from "./interfaces/IInterestRateModel.sol";
import { TSUtils } from "./utils/TSUtils.sol";
import { PoolLib } from "./utils/PoolLib.sol";

contract PoolAccounting is IPoolAccounting, AccessControl {
  using PoolLib for PoolLib.MaturityPool;
  using PoolLib for PoolLib.Position;
  using PoolLib for uint256;
  using FixedPointMathLib for uint256;

  // Vars used in `borrowMP` to avoid
  // stack too deep problem
  struct BorrowVars {
    PoolLib.Position position;
    uint256 feeRate;
    uint256 fee;
    uint256 newUnassignedEarnings;
    uint256 newTreasuryEarnings;
  }

  // Vars used in `repayMP` to avoid
  // stack too deep problem
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
  uint256 public override smartPoolBorrowed;

  IFixedLender public fixedLender;
  IInterestRateModel public interestRateModel;

  uint256 public protocolSpreadFee;
  uint256 public penaltyRate;

  /// @notice emitted when the interestRateModel is changed by admin.
  /// @param newInterestRateModel new interest rate model to be used by this PoolAccounting.
  event InterestRateModelUpdated(IInterestRateModel newInterestRateModel);

  /// @notice emitted when the protocolSpreadFee is changed by admin.
  /// @param newProtocolSpreadFee percentage represented with 1e18 decimals.
  event ProtocolSpreadFeeUpdated(uint256 newProtocolSpreadFee);

  /// @notice emitted when the penaltyRate is changed by admin.
  /// @param newPenaltyRate penaltyRate percentage per second represented with 1e18 decimals.
  event PenaltyRateUpdated(uint256 newPenaltyRate);

  /// @notice emitted when the PoolAccounting is initialized with a FixedLender.
  /// @param fixedLender the FixedLender that is only authorized to call the PoolAccounting functions.
  event Initialized(IFixedLender indexed fixedLender);

  /// @dev only allow calls from the `fixedLender` contract. `fixedLender` should be set through `initialize` method.
  modifier onlyFixedLender() {
    if (msg.sender != address(fixedLender)) revert NotFixedLender();
    _;
  }

  constructor(
    IInterestRateModel _interestRateModel,
    uint256 _penaltyRate,
    uint256 _protocolSpreadFee
  ) {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    interestRateModel = _interestRateModel;

    penaltyRate = _penaltyRate;
    protocolSpreadFee = _protocolSpreadFee;
  }

  /// @dev Initializes the PoolAccounting setting the FixedLender address. Only able to initialize once.
  /// @param _fixedLender the address of the FixedLender that uses this PoolAccounting.
  function initialize(IFixedLender _fixedLender) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (address(fixedLender) != address(0)) revert AlreadyInitialized();

    fixedLender = _fixedLender;
    emit Initialized(_fixedLender);
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

  /// @dev Sets the protocol's spread fee that the treasury earns on borrows.
  /// @param _protocolSpreadFee percentage amount represented with 1e18 decimals.
  function setProtocolSpreadFee(uint256 _protocolSpreadFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
    protocolSpreadFee = _protocolSpreadFee;
    emit ProtocolSpreadFeeUpdated(_protocolSpreadFee);
  }

  /// @dev Function to account for borrowing money from a maturity pool (MP). It doesn't check liquidity for the
  /// borrower, so the `fixedLender` should call `validateBorrowMP` immediately after calling this function.
  /// @param maturityDate maturity date / pool id where the asset will be borrowed.
  /// @param borrower borrower that it will take the debt.
  /// @param amount amount that the borrower will be borrowing.
  /// @param maxAmountAllowed maximum amount that the borrower is willing to pay at maturity.
  /// @param eTokenTotalSupply supply of the smart pool.
  /// @return totalOwedNewBorrow : total amount that will need to be paid at maturity for this borrow.
  function borrowMP(
    uint256 maturityDate,
    address borrower,
    uint256 amount,
    uint256 maxAmountAllowed,
    uint256 eTokenTotalSupply
  )
    external
    override
    onlyFixedLender
    returns (
      uint256 totalOwedNewBorrow,
      uint256 earningsSP,
      uint256 earningsTreasury
    )
  {
    BorrowVars memory borrowVars;
    PoolLib.MaturityPool storage pool = maturityPools[maturityDate];

    earningsSP += pool.accrueEarnings(maturityDate, block.timestamp);

    borrowVars.feeRate = interestRateModel.getRateToBorrow(
      maturityDate,
      block.timestamp,
      amount,
      pool.borrowed,
      pool.supplied,
      eTokenTotalSupply
    );
    borrowVars.fee = amount.fmul(borrowVars.feeRate, 1e18);
    totalOwedNewBorrow = amount + borrowVars.fee;

    smartPoolBorrowed += pool.borrowMoney(amount, eTokenTotalSupply - smartPoolBorrowed);
    // We validate that the user is not taking arbitrary fees
    if (totalOwedNewBorrow > maxAmountAllowed) revert TooMuchSlippage();

    // If user doesn't have a current position, we add it to the list
    // of all of them
    borrowVars.position = mpUserBorrowedAmount[maturityDate][borrower];
    if (borrowVars.position.principal == 0) {
      userMpBorrowed[borrower] = userMpBorrowed[borrower].setMaturity(maturityDate);
    }

    // We distribute to treasury and also to unassigned
    earningsTreasury = borrowVars.fee.fmul(protocolSpreadFee, 1e18);
    (borrowVars.newUnassignedEarnings, borrowVars.newTreasuryEarnings) = PoolLib.distributeEarningsAccordingly(
      borrowVars.fee - earningsTreasury,
      pool.suppliedSP,
      amount
    );
    earningsTreasury += borrowVars.newTreasuryEarnings;
    pool.earningsUnassigned += borrowVars.newUnassignedEarnings;

    mpUserBorrowedAmount[maturityDate][borrower] = PoolLib.Position(
      borrowVars.position.principal + amount,
      borrowVars.position.fee + borrowVars.fee
    );
  }

  /// @dev Function to account for a deposit to a maturity pool (MP). It doesn't transfer or.
  /// @param maturityDate maturity date / pool id where the asset will be deposited.
  /// @param supplier address that will be depositing the assets.
  /// @param amount amount that the supplier will be depositing.
  /// @param minAmountRequired minimum amount that the borrower is expecting to receive at maturity.
  /// @return currentTotalDeposit : the amount that should be collected at maturity for this deposit.
  function depositMP(
    uint256 maturityDate,
    address supplier,
    uint256 amount,
    uint256 minAmountRequired
  ) external override onlyFixedLender returns (uint256 currentTotalDeposit, uint256 earningsSP) {
    PoolLib.MaturityPool storage pool = maturityPools[maturityDate];
    earningsSP = pool.accrueEarnings(maturityDate, block.timestamp);

    (uint256 fee, uint256 feeSP) = interestRateModel.getYieldForDeposit(
      pool.suppliedSP,
      pool.earningsUnassigned,
      amount
    );

    currentTotalDeposit = amount + fee;
    if (currentTotalDeposit < minAmountRequired) revert TooMuchSlippage();

    smartPoolBorrowed -= pool.depositMoney(amount);
    pool.earningsUnassigned -= fee + feeSP;
    earningsSP += feeSP;

    // We update users's position
    PoolLib.Position memory position = mpUserSuppliedAmount[maturityDate][supplier];
    mpUserSuppliedAmount[maturityDate][supplier] = PoolLib.Position(position.principal + amount, position.fee + fee);
  }

  /// @dev Function to account for a withdraw from a maturity pool (MP).
  /// @param maturityDate maturity date / pool id where the asset should be accounted for.
  /// @param redeemer address that should have the assets withdrawn.
  /// @param amount amount that the redeemer will be extracting.
  /// @param maxSPDebt max amount of debt that can be taken from the SP in case of illiquidity.
  function withdrawMP(
    uint256 maturityDate,
    address redeemer,
    uint256 amount,
    uint256 minAmountRequired,
    uint256 maxSPDebt
  )
    external
    override
    onlyFixedLender
    returns (
      uint256 redeemAmountDiscounted,
      uint256 earningsSP,
      uint256 earningsTreasury
    )
  {
    PoolLib.MaturityPool storage pool = maturityPools[maturityDate];

    earningsSP = pool.accrueEarnings(maturityDate, block.timestamp);

    PoolLib.Position memory position = mpUserSuppliedAmount[maturityDate][redeemer];

    // We verify if there are any penalties/fee for him because of
    // early withdrawal - if so: discount
    if (block.timestamp < maturityDate) {
      redeemAmountDiscounted = amount.fdiv(
        1e18 +
          interestRateModel.getRateToBorrow(
            maturityDate,
            block.timestamp,
            amount,
            pool.borrowed + amount, // like asking for a loan full amount
            pool.supplied,
            maxSPDebt
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
      maxSPDebt
    );

    // All the fees go to unassigned or to the treasury
    uint256 earningsUnassigned;
    (earningsUnassigned, earningsTreasury) = PoolLib.distributeEarningsAccordingly(
      amount - redeemAmountDiscounted,
      pool.suppliedSP,
      redeemAmountDiscounted
    );
    pool.earningsUnassigned += earningsUnassigned;

    // the user gets discounted the full amount
    mpUserSuppliedAmount[maturityDate][redeemer] = position.reduceProportionally(amount);
  }

  /// @dev Function to account for a repayment to a maturity pool (MP).
  /// @param maturityDate maturity date / pool id where the asset should be accounted for.
  /// @param borrower address where the debt will be reduced.
  /// @param repayAmount amount that it will be repaid in the MP.
  /// @return actualRepayAmount the amount with discounts included that will finally be transferred.
  /// @return debtCovered the sum of principal and fees that this repayment covers.
  /// @return earningsSP amount of earnings to be accrued by the smart pool depositors.
  /// @return earningsTreasury amount of earnings to be accrued by the protocol's treasury.
  function repayMP(
    uint256 maturityDate,
    address borrower,
    uint256 repayAmount,
    uint256 maxAmountAllowed
  )
    external
    override
    onlyFixedLender
    returns (
      uint256 actualRepayAmount,
      uint256 debtCovered,
      uint256 earningsSP,
      uint256 earningsTreasury
    )
  {
    RepayVars memory repayVars;

    PoolLib.MaturityPool storage pool = maturityPools[maturityDate];

    // SP supply needs to accrue its interests
    earningsSP = pool.accrueEarnings(maturityDate, block.timestamp);

    // Amount Owed is (principal+fees)*penalties
    repayVars.amountOwed = getAccountDebt(borrower, maturityDate);
    repayVars.position = mpUserBorrowedAmount[maturityDate][borrower];

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
    if (block.timestamp < maturityDate) {
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
      // We distribute penalties to those that supported (pre-repayment)
      uint256 newEarningsSP;
      (newEarningsSP, earningsTreasury) = PoolLib.distributeEarningsAccordingly(
        repayAmount - (repayVars.scaleDebtCovered.principal + repayVars.scaleDebtCovered.fee),
        pool.suppliedSP,
        repayVars.scaleDebtCovered.principal
      );
      earningsSP += newEarningsSP;
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
      delete mpUserBorrowedAmount[maturityDate][borrower];
      userMpBorrowed[borrower] = userMpBorrowed[borrower].clearMaturity(maturityDate);
    } else {
      // we proportionally reduce the values
      mpUserBorrowedAmount[maturityDate][borrower] = repayVars.position;
    }
  }

  /// @dev Gets all borrows for a wallet in certain maturity (or MATURITY_ALL).
  /// @param who wallet to return status snapshot in the specified maturity date.
  /// @param maturityDate maturityDate where the borrow is taking place. MATURITY_ALL returns all borrows.
  /// @return debt the amount the user deposited to the smart pool and the total money he owes from maturities.
  function getAccountBorrows(address who, uint256 maturityDate) public view override returns (uint256 debt) {
    if (maturityDate == PoolLib.MATURITY_ALL) {
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
    } else debt = getAccountDebt(who, maturityDate);
  }

  /// @dev Gets the total amount of borrowed money for a maturityDate.
  /// @param maturityDate maturity date.
  function getTotalMpBorrows(uint256 maturityDate) public view override returns (uint256) {
    return maturityPools[maturityDate].borrowed;
  }

  /// @notice Internal function to get the debt + penalties of an account for a certain maturityDate.
  /// @param who wallet to return debt status for the specified maturityDate.
  /// @param maturityDate amount to be transfered.
  /// @return totalDebt : the total debt denominated in number of tokens.
  function getAccountDebt(address who, uint256 maturityDate) internal view returns (uint256 totalDebt) {
    PoolLib.Position memory position = mpUserBorrowedAmount[maturityDate][who];
    totalDebt = position.principal + position.fee;
    uint256 secondsDelayed = TSUtils.secondsPre(maturityDate, block.timestamp);
    if (secondsDelayed > 0) totalDebt += totalDebt.fmul(secondsDelayed * penaltyRate, 1e18);
  }
}
