// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./TSUtils.sol";

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
        uint256 earnings;
        uint256 earningsSP;
        uint256 lastAccrue;
    }

    /**
     * @notice function that registers an operation to add money to
     *         maturity pool that returns how much earnings will be shared
     *         for that amount supplied
     * @param pool maturity pool where money will be added
     * @param maturityID timestamp in which maturity pool matures
     * @param amount amount to be added to the maturity pool
     */
    function addMoney(
        MaturityPool storage pool,
        uint256 maturityID,
        uint256 amount
    ) external returns (uint256) {
        // we use this function to accrue only
        // by passing 0 fees
        _accrueAndAddFee(pool, maturityID, 0);

        pool.supplied += amount;

        // from now on, it's earnings calculations
        uint256 supply = pool.suppliedSP + amount;
        uint256 earnings = pool.earnings;
        uint256 earningsShare = supply == 0 ? 0 : (amount * earnings) / supply;
        pool.earnings -= earningsShare;
        return earningsShare;
    }

    /**
     * @notice function that registers an operation to take money out of the
     *         maturity pool that returns if there's new debt to be taken out
     *         of the smart pool
     * @param pool maturity pool where money needs to be taken out
     * @param amount amount to be taken out of the pool before it matures
     */
    function takeMoney(MaturityPool storage pool, uint256 amount)
        external
        returns (uint256)
    {
        uint256 oldBorrowed = pool.borrowed;
        uint256 newBorrowed = pool.borrowed + amount;
        pool.borrowed = newBorrowed;

        uint256 supplied = pool.supplied + pool.suppliedSP;
        uint256 newDebtSP = 0;

        if (oldBorrowed > supplied) {
            newDebtSP = amount;
            pool.suppliedSP += amount;
        } else if (newBorrowed > supplied) {
            // this means that it's not "if (newBorrow <= supplied)" in this
            // case we take a little part from smart pool
            newDebtSP = newBorrowed - supplied;
            pool.suppliedSP += newBorrowed - supplied;
        }

        return newDebtSP;
    }

    /**
     * @notice External function to accrue Smart Pool earnings and (possibly)
     *         add more earnings to the pool to be collected at maturity
     * @param pool maturity pool that needs to be updated
     * @param maturityID timestamp in which maturity pool matures
     * @param commission (optional) commission to be added to the earnings for
     *                   the pool at maturity
     */
    function addFee(
        MaturityPool storage pool,
        uint256 maturityID,
        uint256 commission
    ) internal {
        _accrueAndAddFee(pool, maturityID, commission);
    }

    /**
     * @notice Internal function to accrue Smart Pool earnings and (possibly)
     *         add more earnings to the pool to be collected at maturity
     * @param pool maturity pool that needs to be updated
     * @param maturityID timestamp in which maturity pool matures
     * @param commission (optional) commission to be added to the earnings for
     *                   the pool at maturity
     */
    function _accrueAndAddFee(
        MaturityPool storage pool,
        uint256 maturityID,
        uint256 commission
    ) internal {
        if (pool.lastAccrue == 0) {
            pool.lastAccrue = Math.min(maturityID, block.timestamp);
        }

        uint256 daysToAccrue = TSUtils.daysPre(
            pool.lastAccrue,
            Math.min(maturityID, block.timestamp)
        );
        uint256 daysTotal = TSUtils.daysPre(pool.lastAccrue, maturityID);
        uint256 earnings = pool.earnings;

        uint256 earningsToAccrue = daysTotal == 0
            ? 0
            : (earnings * daysToAccrue) / daysTotal;
        pool.earningsSP += earningsToAccrue;
        pool.earnings = earnings - earningsToAccrue + commission;
        pool.lastAccrue = Math.min(maturityID, block.timestamp);
    }
}
