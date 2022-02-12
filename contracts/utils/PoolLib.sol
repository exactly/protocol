// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./TSUtils.sol";
import "./Errors.sol";
import "hardhat/console.sol";

library PoolLib {
    /**
     * @notice struct that helps manage the maturity pools and also keep
     * @param borrowed total amount borrowed at the MP
     * @param supplied total amount supplied to the MP
     * @param suppliedSP total amount borrowed over time from the SP.
     *        It's worth noticing that it only increases, and it's the last
     *        debt to be repaid at maturity
     * @param earnings total amount of earnings to be collected at maturity.
     *        This earnings haven't accrued yet (see: lastAccrue). Each interaction
     *        with the MP, some of these earnings are accrued to earningsSP. This is
     *        done by doing:
     *             EARNINGSSP += DAYS(NOW - LAST_ACCRUE) * EARNINGS /
     *                              DAYS(MATURITY_DATE - LAST_ACCRUE)
     *        If there's a new deposit to the MP, the commission for that deposit comes
     *        out of the future earnings:
     *              NEWCOMMISSION = DEPOSIT * EARNINGS / (SUPPLIEDSP + DEPOSIT);
     *              EARNINGS -= NEWCOMMISSION;
     * @param earningsSP total amount of earnings that already belong to the SP
     * @param lastAccrue timestamp for the last time that some of the earnings
     *        have been transferred to earningsSP (SP gained some earnings for having
     *        supported the loans)
     */
    struct MaturityPool {
        uint256 borrowed;
        uint256 supplied;
        uint256 suppliedSP;
        uint256 unassignedEarnings;
        uint256 earningsMP;
        uint256 earningsSP;
        uint256 lastAccrue;
    }

    struct RepayVars {
        uint256 borrowMP;
        uint256 earningsSP;
        uint256 earningsMP;
        uint256 unassignedEarnings;
        uint256 earningsSPReduce;
        uint256 earningsMPReduce;
        uint256 unassignedEarningsReduce;
        uint256 earningsAll;
        uint256 supplySP;
    }

    struct Debt {
        uint256 principals;
        uint256 fees;
    }

    /**
     * @notice function that registers an operation to add money to
     *         maturity pool
     * @param pool maturity pool where money will be added
     * @param amount amount to be added to the maturity pool
     */
    function addMoney(MaturityPool storage pool, uint256 amount) external {
        pool.supplied += amount;
    }

    /**
     * @notice function that registers an operation to take money out of the
     *         maturity pool that returns if there's new debt to be taken out
     *         of the smart pool
     * @param pool maturity pool where money needs to be taken out
     * @param amount amount to be taken out of the pool before it matures
     * @return newDebtSP amount of new debt that needs to be taken out of the SP
     */
    function takeMoney(
        MaturityPool storage pool,
        uint256 amount,
        uint256 maxDebt
    ) external returns (uint256 newDebtSP) {
        uint256 newBorrowedMP = pool.borrowed + amount;
        uint256 suppliedMP = pool.supplied;
        uint256 suppliedALL = pool.suppliedSP + suppliedMP;

        if (newBorrowedMP > suppliedALL) {
            uint256 newSupplySP = newBorrowedMP - suppliedMP;

            if (newSupplySP > maxDebt) {
                revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
            }

            // We take money out from the Smart Pool
            // because there's not enough in the MP
            newDebtSP = newBorrowedMP - suppliedALL;
            pool.suppliedSP = newSupplySP;
        }

        pool.borrowed = newBorrowedMP;
    }

    /**
     * @notice function that registers an operation to withdraw money out of the
     *         maturity pool that returns if there's new debt to be taken out
     *         of the smart pool
     * @param pool maturity pool where money needs to be withdrawn
     * @param amount amount to be taken out of the pool before it matures
     * @return newDebtSP amount of new debt that needs to be taken out of the SP
     */
    function withdrawMoney(
        MaturityPool storage pool,
        uint256 amount,
        uint256 maxDebt
    ) external returns (uint256 newDebtSP) {
        uint256 borrowedMP = pool.borrowed;
        uint256 newSuppliedMP = pool.supplied - amount;
        uint256 newSuppliedALL = pool.suppliedSP + newSuppliedMP;

        // by reducing supply we might need to take debt from SP
        if (borrowedMP > newSuppliedALL) {
            // We verify the SP is not taking too much debt
            uint256 newSupplySP = borrowedMP - newSuppliedMP;
            if (newSupplySP > maxDebt) {
                revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
            }

            // We take money out from the Smart Pool
            // because there's not enough in the MP
            newDebtSP = borrowedMP - newSuppliedALL;
            pool.suppliedSP = newSupplySP;
        }

        pool.supplied = newSuppliedALL;
    }

    /**
     * @notice function that registers an operation to repay to
     *         maturity pool. Reduces the amount of supplied amount by
     *         MP depositors, after that reduces SP debt, and finally
     *         returns the amount of earnings to pay to SP
     * @param pool maturity pool where money will be added
     * @param debt _Debt_ to be reduced from the pool
     * @return smartPoolDebtReduction : amount to reduce the SP debt
     * @return feeRepay : amount to distribute as earnings to the SP (revenue share with protocol)
     * @return earningsRepay : amount to distribute as earnings to the SP - extras (penalties,
     *         not shared with anyone)
     */
    function repay(MaturityPool storage pool, Debt memory debt)
        external
        returns (
            uint256 smartPoolDebtReduction,
            uint256 feeRepay,
            uint256 earningsRepay
        )
    {
        RepayVars memory repayVars;
        repayVars.borrowMP = pool.borrowed;
        repayVars.earningsSP = pool.earningsSP;
        repayVars.earningsMP = pool.earningsMP;
        repayVars.unassignedEarnings = pool.unassignedEarnings;
        repayVars.earningsAll =
            repayVars.earningsSP +
            repayVars.earningsMP +
            repayVars.unassignedEarnings;
        repayVars.supplySP = pool.suppliedSP;

        // NOTES re: principal to only reduce borrow
        //     * you can't use principal to pay anything else (ppal with ppal and earnings with earnings)
        //     * you can't do asimmetric payment, because you would be altering the values for the following operations
        //       ie: You use the earnings to pay all the earningsSP first, so the function _returnFee_ will change the
        //           values for after
        pool.borrowed = repayVars.borrowMP - debt.principals;

        // NOTES re: smart pool debt
        //       we repay the debt immediately
        // TODO: get the fee for the SPDebt takeover
        smartPoolDebtReduction = Math.min(repayVars.supplySP, debt.principals);
        pool.suppliedSP = repayVars.supplySP - smartPoolDebtReduction;

        // NOTES:
        //     * you can't do asimmetric payment, because you would be altering the values for the following operations
        //       ie: You use the earnings to pay all the earningsSP first, so the function _returnFee_ will change the
        //           values for after
        if (repayVars.earningsAll == 0) {
            earningsRepay = debt.fees;
        } else {
            repayVars.earningsMPReduce = ((repayVars.earningsMP * debt.fees) /
                repayVars.earningsAll);
            repayVars.earningsSPReduce = ((repayVars.earningsSP * debt.fees) /
                repayVars.earningsAll);
            repayVars.unassignedEarningsReduce = Math.min(
                repayVars.unassignedEarnings,
                debt.fees -
                    repayVars.earningsMPReduce -
                    repayVars.earningsSPReduce
            );

            pool.earningsMP = repayVars.earningsMP - repayVars.earningsMPReduce;
            pool.earningsSP = repayVars.earningsSP - repayVars.earningsSPReduce;
            pool.unassignedEarnings =
                repayVars.unassignedEarnings -
                repayVars.unassignedEarningsReduce;

            // return value smartPoolDebtReduction = extra from principal
            feeRepay = repayVars.earningsSPReduce;
            // all the rest goes to the SP as earnings
            earningsRepay =
                debt.fees -
                repayVars.earningsMPReduce -
                repayVars.earningsSPReduce;
        }
    }

    /**
     * @notice External function to add fee to be collected at maturity
     * @param pool maturity pool that needs to be updated
     * @param fee fee to be added to the earnings for the pool at maturity
     */
    function addFee(MaturityPool storage pool, uint256 fee) external {
        pool.unassignedEarnings += fee;
    }

    /**
     * @notice External function to remove fee to be collected from the maturity pool
     * @param pool maturity pool that needs to be updated
     * @param fee fee to be removed from the unassigned earnings
     */
    function removeFee(MaturityPool storage pool, uint256 fee) external {
        pool.unassignedEarnings -= fee;
    }

    /**
     * @notice External function to take a fee out of earnings at maturity
     * @param pool maturity pool that needs to be updated
     * @param fee fee to be added to the earnings for
     *                   the pool at maturity
     */
    function takeFee(MaturityPool storage pool, uint256 fee) external {
        pool.unassignedEarnings -= fee;
        pool.earningsMP += fee;
    }

    /**
     * @notice External function to return a fee to be collected a maturity
     * @param pool maturity pool that needs to be updated
     * @param fee fee to be removed to the earnings for the pool at maturity
     */
    function returnFee(MaturityPool storage pool, uint256 fee) external {
        pool.earningsMP -= fee;
    }

    /**
     * @notice External function to accrue Smart Pool earnings
     * @param pool maturity pool that needs to be updated
     * @param maturityID timestamp in which maturity pool matures
     */
    function accrueEarningsToSP(MaturityPool storage pool, uint256 maturityID)
        external
    {
        if (pool.lastAccrue == maturityID) {
            return;
        }

        // seconds from last accrual to the closest:
        // maturity date or the current timestamp
        uint256 secondsSinceLastAccrue = TSUtils.secondsPre(
            pool.lastAccrue,
            Math.min(maturityID, block.timestamp)
        );
        // seconds from last accrual to the maturity date
        uint256 secondsTotalToMaturity = TSUtils.secondsPre(
            pool.lastAccrue,
            maturityID
        );
        uint256 unassignedEarnings = pool.unassignedEarnings;

        // assign some of the earnings to be collected at maturity
        uint256 earningsToAccrue = secondsTotalToMaturity == 0
            ? 0
            : (unassignedEarnings * secondsSinceLastAccrue) /
                secondsTotalToMaturity;
        pool.earningsSP += earningsToAccrue;
        pool.unassignedEarnings = unassignedEarnings - earningsToAccrue;
        pool.lastAccrue = Math.min(maturityID, block.timestamp);
    }

    function scaleProportionally(Debt memory debt, uint256 amount)
        external
        pure
        returns (Debt memory)
    {
        // we proportionally reduce the values
        uint256 principals = (debt.principals * amount) /
            (debt.principals + debt.fees);
        debt.principals = principals;
        debt.fees = amount - principals;
        return debt;
    }

    function reduceProportionally(Debt memory debt, uint256 amount)
        external
        pure
        returns (Debt memory)
    {
        // we proportionally reduce the values
        uint256 principals = (debt.principals * amount) /
            (debt.principals + debt.fees);
        debt.principals -= principals;
        debt.fees -= amount - principals;
        return debt;
    }

    function reduceFees(Debt memory debt, uint256 fees)
        external
        pure
        returns (Debt memory)
    {
        // we only reduce the fees
        debt.fees = debt.fees - fees;
        return debt;
    }
}
