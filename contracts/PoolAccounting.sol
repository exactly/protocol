// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";

import "./interfaces/IEToken.sol";
import "./interfaces/IInterestRateModel.sol";
import "./interfaces/IPoolAccounting.sol";
import "./interfaces/IFixedLender.sol";
import "./utils/TSUtils.sol";
import "./utils/DecimalMath.sol";
import "./utils/Errors.sol";
import "hardhat/console.sol";

contract PoolAccounting is IPoolAccounting, AccessControl {
    using PoolLib for PoolLib.MaturityPool;
    using PoolLib for PoolLib.Position;
    using DecimalMath for uint256;

    // Vars used in `borrowMP` to avoid
    // stack too deep problem
    struct BorrowVars {
        PoolLib.Position debt;
        uint256 feeRate;
        uint256 fee;
    }

    // Vars used in `repayMP` to avoid
    // stack too deep problem
    struct RepayVars {
        uint256 discountFee;
        uint256 feeSP;
        uint256 amountOwed;
        PoolLib.Position debt;
        uint256 amountStillBorrowed;
        uint256 smartPoolDebtReduction;
    }

    mapping(uint256 => mapping(address => PoolLib.Position))
        public mpUserSuppliedAmount;
    mapping(uint256 => mapping(address => PoolLib.Position))
        public mpUserBorrowedAmount;

    mapping(address => uint256[]) public userMpBorrowed;
    mapping(uint256 => PoolLib.MaturityPool) public maturityPools;
    uint256 public override smartPoolBorrowed;

    address private fixedLenderAddress;
    IInterestRateModel public interestRateModel;

    event Initialized(address indexed fixedLender);

    /**
     * @dev modifier used to allow calls to certain functions only from
     * the `fixedLender` contract. `fixedLenderAddress` should be set
     * through `initialize` method
     */
    modifier onlyFixedLender() {
        if (msg.sender != address(fixedLenderAddress)) {
            revert GenericError(ErrorCode.CALLER_MUST_BE_FIXED_LENDER);
        }
        _;
    }

    constructor(address _interestRateModelAddress) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        interestRateModel = IInterestRateModel(_interestRateModelAddress);
    }

    /**
     * @dev Initializes the PoolAccounting setting the FixedLender address
     * - Only able to initialize once
     * @param _fixedLenderAddress The address of the FixedLender that uses this PoolAccounting
     */
    function initialize(address _fixedLenderAddress)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (fixedLenderAddress != address(0)) {
            revert GenericError(ErrorCode.CONTRACT_ALREADY_INITIALIZED);
        }

        fixedLenderAddress = _fixedLenderAddress;

        emit Initialized(_fixedLenderAddress);
    }

    /**
     * @dev Function to account for borrowing money from a maturity pool (MP).
     *      It doesn't check liquidity for the borrower, so the `fixedLender`
     *      should call `validateBorrowMP` immediately after calling this function.
     * @param maturityDate maturity date / pool id where the asset will be borrowed
     * @param borrower borrower that it will take the debt
     * @param amount amount that the borrower will be borrowing
     * @param maxAmountAllowed maximum amount that the borrower is willing to pay
     *        at maturity
     * @param maxSPDebt maximum amount of assset debt that the MP can have with the SP
     * @return totalOwedNewBorrow : total amount that will need to be paid at maturity for this borrow
     */
    function borrowMP(
        uint256 maturityDate,
        address borrower,
        uint256 amount,
        uint256 maxAmountAllowed,
        uint256 maxSPDebt
    )
        external
        override
        onlyFixedLender
        returns (uint256 totalOwedNewBorrow, uint256 earningsSP)
    {
        BorrowVars memory borrowVars;

        PoolLib.MaturityPool storage pool = maturityPools[maturityDate];

        earningsSP += pool.accrueEarnings(maturityDate, currentTimestamp());
        smartPoolBorrowed += pool.takeMoney(amount, maxSPDebt);

        borrowVars.feeRate = interestRateModel.getRateToBorrow(
            maturityDate,
            block.timestamp,
            pool.borrowed,
            pool.supplied,
            maxSPDebt
        );
        borrowVars.fee = amount.mul_(borrowVars.feeRate);
        totalOwedNewBorrow = amount + borrowVars.fee;

        if (totalOwedNewBorrow > maxAmountAllowed) {
            revert GenericError(ErrorCode.TOO_MUCH_SLIPPAGE);
        }

        borrowVars.debt = mpUserBorrowedAmount[maturityDate][borrower];
        if (borrowVars.debt.principal == 0) {
            userMpBorrowed[borrower].push(maturityDate);
        }

        // TODO: add treasury fee here
        pool.addFee(borrowVars.fee);

        mpUserBorrowedAmount[maturityDate][borrower] = PoolLib.Position(
            borrowVars.debt.principal + amount,
            borrowVars.debt.fee + borrowVars.fee
        );
    }

    /**
     * @dev Function to account for a deposit to a maturity pool (MP). It doesn't transfer or
     * @param maturityDate maturity date / pool id where the asset will be deposited
     * @param supplier address that will be depositing the assets
     * @param amount amount that the supplier will be depositing
     * @param minAmountRequired minimum amount that the borrower is expecting to receive at
     *        maturity
     * @return currentTotalDeposit : the amount that should be collected at maturity for this deposit
     */
    function depositMP(
        uint256 maturityDate,
        address supplier,
        uint256 amount,
        uint256 minAmountRequired
    )
        external
        override
        onlyFixedLender
        returns (uint256 currentTotalDeposit, uint256 earningsSP)
    {
        earningsSP = maturityPools[maturityDate].accrueEarnings(
            maturityDate,
            currentTimestamp()
        );

        (uint256 fee, uint256 feeSP) = interestRateModel.getYieldForDeposit(
            maturityPools[maturityDate].suppliedSP,
            maturityPools[maturityDate].borrowed,
            maturityPools[maturityDate].earningsUnassigned,
            amount,
            IFixedLender(fixedLenderAddress).mpDepositDistributionWeighter()
        );

        currentTotalDeposit = amount + fee;
        if (currentTotalDeposit < minAmountRequired) {
            revert GenericError(ErrorCode.TOO_MUCH_SLIPPAGE);
        }

        smartPoolBorrowed -= maturityPools[maturityDate].addMoney(amount);
        maturityPools[maturityDate].removeFee(fee);
        earningsSP += feeSP;

        // We update users's position
        PoolLib.Position memory debt = mpUserSuppliedAmount[maturityDate][
            supplier
        ];
        mpUserSuppliedAmount[maturityDate][supplier] = PoolLib.Position(
            debt.principal + amount,
            debt.fee + fee
        );
    }

    /**
     * @dev Function to account for a withdraw from a maturity pool (MP).
     * @param maturityDate maturity date / pool id where the asset should be accounted for
     * @param redeemer address that should have the assets withdrawn
     * @param amount amount that the redeemer will be extracting
     * @param maxSPDebt max amount of debt that can be taken from the SP in case of illiquidity
     */
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
        returns (uint256 redeemAmountDiscounted, uint256 earningsSP)
    {
        earningsSP = maturityPools[maturityDate].accrueEarnings(
            maturityDate,
            currentTimestamp()
        );

        PoolLib.Position memory debt = mpUserSuppliedAmount[maturityDate][
            redeemer
        ];

        // We remove the supply from the offer
        smartPoolBorrowed += maturityPools[maturityDate].withdrawMoney(
            debt.scaleProportionally(amount).principal,
            maxSPDebt
        );

        // We verify if there are any penalties/fee for him because of
        // early withdrawal
        if (currentTimestamp() < maturityDate) {
            PoolLib.MaturityPool storage pool = maturityPools[maturityDate];

            uint256 feeRate = interestRateModel.getRateToBorrow(
                maturityDate,
                block.timestamp,
                pool.borrowed,
                pool.supplied,
                maxSPDebt
            );
            redeemAmountDiscounted = amount.div_(1e18 + feeRate);
        } else {
            redeemAmountDiscounted = amount;
        }

        if (redeemAmountDiscounted < minAmountRequired) {
            revert GenericError(ErrorCode.TOO_MUCH_SLIPPAGE);
        }

        // and we cancelled some future fees at maturity
        // (instead of transferring to the depositor)
        maturityPools[maturityDate].removeFee(amount - redeemAmountDiscounted);

        // the user gets discounted the full amount
        mpUserSuppliedAmount[maturityDate][redeemer] = debt
            .reduceProportionally(amount);
    }

    /**
     * @dev Function to account for a repayment to a maturity pool (MP).
     * @param maturityDate maturity date / pool id where the asset should be accounted for
     * @param borrower address where the debt will be reduced
     * @param repayAmount amount that it will be repaid in the MP
     */
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
            uint256 spareRepayAmount,
            uint256 debtCovered,
            uint256 earningsSP
        )
    {
        RepayVars memory repayVars;

        // SP supply needs to accrue its interests
        earningsSP = maturityPools[maturityDate].accrueEarnings(
            maturityDate,
            currentTimestamp()
        );

        // Amount Owed is (principal+fees)*penalties
        repayVars.amountOwed = getAccountBorrows(borrower, maturityDate);
        repayVars.debt = mpUserBorrowedAmount[maturityDate][borrower];

        // We calculate the amount of the debt this covers, paying proportionally
        // the amount of interests on the overdue debt. If repay amount = amount owed,
        // then amountBorrowed is what should be discounted to the users account
        // Math.min to not go over repayAmount since we return exceeding money, but
        // hasn't been calculated yet
        debtCovered = Math.min(
            (repayAmount * (repayVars.debt.principal + repayVars.debt.fee)) /
                repayVars.amountOwed,
            repayVars.amountOwed
        );

        // Early repayment allows you to get a discount from the unassigned earnings
        if (currentTimestamp() < maturityDate) {
            // We calculate the deposit fee considering the amount
            // of debt he'll pay
            (repayVars.discountFee, repayVars.feeSP) = interestRateModel
                .getYieldForDeposit(
                    maturityPools[maturityDate].suppliedSP,
                    maturityPools[maturityDate].borrowed,
                    maturityPools[maturityDate].earningsUnassigned,
                    repayVars.debt.scaleProportionally(debtCovered).principal,
                    // ^ this case shouldn't contain penalties since is before maturity date
                    IFixedLender(fixedLenderAddress)
                        .mpDepositDistributionWeighter()
                );

            earningsSP += repayVars.feeSP;

            // We verify that the user agrees to this discount
            if (debtCovered - repayVars.discountFee > maxAmountAllowed) {
                revert GenericError(ErrorCode.TOO_MUCH_SLIPPAGE);
            }

            // We remove the fee from unassigned earnings
            maturityPools[maturityDate].removeFee(repayVars.discountFee);
        }

        // user paid more than it should. The fee gets kicked back to the user
        // through _spareRepayAmount_ and on the pool side it was removed by
        // calling _removeFee_ a few lines before ^
        if (repayAmount > repayVars.amountOwed - repayVars.discountFee) {
            spareRepayAmount =
                repayAmount -
                (repayVars.amountOwed - repayVars.discountFee);
            repayAmount = repayVars.amountOwed;
            debtCovered = Math.min(
                debtCovered,
                (repayVars.debt.principal + repayVars.debt.fee)
            );
        } else {
            spareRepayAmount = repayVars.discountFee;
        }

        repayVars.amountStillBorrowed =
            (repayVars.debt.principal + repayVars.debt.fee) -
            debtCovered;

        if (repayVars.amountStillBorrowed == 0) {
            cleanPosition(borrower, maturityDate);
        } else {
            // we proportionally reduce the values
            mpUserBorrowedAmount[maturityDate][borrower] = repayVars
                .debt
                .scaleProportionally(repayVars.amountStillBorrowed);
        }

        // We reduce the borrowed and we might decrease the SP debt
        PoolLib.Position memory scaledDebt = repayVars.debt.scaleProportionally(
            debtCovered
        );
        repayVars.smartPoolDebtReduction = maturityPools[maturityDate]
            .repayMoney(scaledDebt.principal);
        smartPoolBorrowed -= repayVars.smartPoolDebtReduction;
    }

    /**
     * @dev Gets all borrows for a wallet in certain maturity (or ALL_MATURITIES)
     * @param who wallet to return status snapshot in the specified maturity date
     * @param maturityDate maturityDate where the borrow is taking place.
     * - Send the value 0 in order to get the snapshot for all maturities where the user borrowed
     * @return debt the amount the user deposited to the smart pool and the total money he owes from maturities
     */
    function getAccountBorrows(address who, uint256 maturityDate)
        public
        view
        override
        returns (uint256 debt)
    {
        if (maturityDate == 0) {
            uint256 borrowsLength = userMpBorrowed[who].length;
            for (uint256 i = 0; i < borrowsLength; i++) {
                debt += getAccountDebt(who, userMpBorrowed[who][i]);
            }
        } else {
            if (!TSUtils.isPoolID(maturityDate)) {
                revert GenericError(ErrorCode.INVALID_POOL_ID);
            }
            debt = getAccountDebt(who, maturityDate);
        }
    }

    /**
     * @dev Gets the total amount of borrowed money for a maturityDate
     * @param maturityDate maturity date
     */
    function getTotalMpBorrows(uint256 maturityDate)
        public
        view
        override
        returns (uint256)
    {
        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }
        return maturityPools[maturityDate].borrowed;
    }

    /**
     * @dev Cleans user's position from the blockchain making sure space is freed
     * @param borrower user's wallet
     * @param maturityDate maturity date
     */
    function cleanPosition(address borrower, uint256 maturityDate) internal {
        uint256[] memory userMaturitiesBorrowedList = userMpBorrowed[borrower];
        uint256 len = userMaturitiesBorrowedList.length;
        uint256 maturityIndex = len;
        for (uint256 i = 0; i < len; i++) {
            if (userMaturitiesBorrowedList[i] == maturityDate) {
                maturityIndex = i;
                break;
            }
        }

        // We *must* have found the maturity in the list or our redundant data structure is broken
        assert(maturityIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        uint256[] storage storedList = userMpBorrowed[borrower];
        storedList[maturityIndex] = storedList[storedList.length - 1];
        storedList.pop();

        delete mpUserBorrowedAmount[maturityDate][borrower];
    }

    /**
     * @notice Internal function to get the debt + penalties of an account for a certain maturityDate
     * @param who wallet to return debt status for the specified maturityDate
     * @param maturityDate amount to be transfered
     * @return totalDebt : the total debt denominated in number of tokens
     */
    function getAccountDebt(address who, uint256 maturityDate)
        internal
        view
        returns (uint256 totalDebt)
    {
        PoolLib.Position memory debt = mpUserBorrowedAmount[maturityDate][who];
        totalDebt = debt.principal + debt.fee;
        uint256 secondsDelayed = TSUtils.secondsPre(
            maturityDate,
            currentTimestamp()
        );
        if (secondsDelayed > 0) {
            totalDebt += totalDebt.mul_(
                secondsDelayed * interestRateModel.penaltyRate()
            );
        }
    }

    /**
     * @notice Internal/virtual function to get the current timestamp (it gets overriden
     *         when writing tests)
     * @return current timestamp
     */
    function currentTimestamp() internal view virtual returns (uint256) {
        return block.timestamp;
    }
}
