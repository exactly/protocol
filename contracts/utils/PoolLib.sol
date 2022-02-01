// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./TSUtils.sol";
import "./Errors.sol";

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
        uint256 newBorrowed = pool.borrowed + amount;
        pool.borrowed = newBorrowed;

        uint256 suppliedSP = pool.suppliedSP;
        uint256 suppliedMP = pool.supplied;
        uint256 supplied = suppliedSP + suppliedMP;

        if (newBorrowed > supplied) {
            uint256 newSupplySP = newBorrowed - suppliedMP;

            if (newSupplySP > maxDebt) {
                revert GenericError(ErrorCode.INSUFFICIENT_PROTOCOL_LIQUIDITY);
            }

            // We take money out from the Smart Pool
            // because there's not enough in the MP
            newDebtSP = newBorrowed - supplied;
            pool.suppliedSP = newSupplySP;
        }
    }

    /**
     * @notice function that registers an operation to repay to
     *         maturity pool. Reduces the amount of supplied amount by
     *         MP depositors, after that reduces SP debt, and finally
     *         returns the amount of earnings to pay to SP
     * @param pool maturity pool where money will be added
     * @param amount amount to be added to the maturity pool
     * @return smartPoolDebtReduction : amount to reduce the SP debt
     * @return fee : amount to distribute as earnings to the SP (revenue share with protocol)
     * @return earningsRepay : amount to distribute as earnings to the SP - extras (penalties,
     *         not shared with anyone)
     */
    function repay(MaturityPool storage pool, uint256 amount)
        external
        returns (
            uint256 smartPoolDebtReduction,
            uint256 fee,
            uint256 earningsRepay
        )
    {
        uint256 borrowMP = pool.borrowed;
        uint256 supplySP = pool.suppliedSP;
        uint256 earningsSP = pool.earningsSP;

        // You can't have repayments bigger than the borrowed amount
        // but amount might contain the fees or penalties
        pool.borrowed = borrowMP - Math.min(borrowMP, amount);

        // This is the amount that is being lent out by the protocol
        // that belongs to the MP depositors
        uint256 depositsBorrowed = borrowMP - Math.min(borrowMP, supplySP);
        if (amount > depositsBorrowed) {
            // if its more than the amount being repaid, then it should
            // take a little part of the SP debt
            uint256 extra = amount - depositsBorrowed;

            uint256 earningsDebtMP = Math.min(pool.earningsMP, extra);
            pool.earningsMP -= earningsDebtMP;
            extra -= earningsDebtMP;
            if (extra <= supplySP) {
                // Covered part of the supply SP
                pool.suppliedSP -= extra;
                smartPoolDebtReduction = extra;
                // unchanged values:
                //   fee = 0
                //   earningsRepay = 0
            } else if (extra < supplySP + earningsSP) {
                // Covered the supply SP and part of the earningsSP
                pool.suppliedSP = 0;
                extra -= supplySP;
                pool.earningsSP -= extra;

                smartPoolDebtReduction = supplySP;
                fee = extra;
                // unchanged values:
                //   earningsRepay = 0
            } else {
                // Covered the supply SP and the earnings SP and extras SP
                smartPoolDebtReduction = supplySP;
                fee = pool.earningsSP;
                earningsRepay =
                    extra -
                    supplySP -
                    fee -
                    pool.unassignedEarnings;

                pool.suppliedSP = 0;
                pool.earningsSP = 0;
            }
        }

        // No smart pool debt reduction
        // No revenue for smart pool and protocol
        // No extras for smart pool
        //   smartPoolDebtReduction = 0
        //   fee = 0
        //   earningsRepay = 0
    }

    /**
     * @notice External function to add fee to be collected at maturity
     * @param pool maturity pool that needs to be updated
     * @param fee fee to be added to the earnings for
     *                   the pool at maturity
     */
    function addFee(MaturityPool storage pool, uint256 fee) external {
        pool.unassignedEarnings += fee;
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
}
