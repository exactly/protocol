// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./TSUtils.sol";
import "hardhat/console.sol";

library PoolLib {
    struct MaturityPool {
        uint256 borrowed;
        uint256 supplied;
        uint256 suppliedSP;
        uint256 earnings;
        uint256 earningsSP;
        uint256 lastAccrue;
    }

    function addMoney(
        MaturityPool storage pool,
        uint256 maturityID,
        uint256 amount
    ) external returns (uint256) {
        // we use this function to accrue only
        // by passing 0 fees
        _accrueAndAddFee(pool, maturityID, 0);

        uint256 oldSupplied = pool.supplied;
        uint256 newSupplied = oldSupplied + amount;
        pool.supplied = newSupplied;

        // from now on, it's earnings calculations
        uint256 supply = pool.suppliedSP + amount;
        uint256 earnings = pool.earnings;
        uint256 earningsShare = supply == 0 ? 0 : (amount * earnings) / supply;
        pool.earnings -= earningsShare;
        return earningsShare;
    }

    function takeMoney(
        MaturityPool storage pool,
        uint256 smartPoolTotalDebt,
        uint256 amountBorrow
    ) external returns (uint256) {
        uint256 oldBorrowed = pool.borrowed;
        uint256 supplied = pool.supplied;
        uint256 newBorrowed = pool.borrowed + amountBorrow;

        pool.borrowed = newBorrowed;

        if (oldBorrowed > supplied) {
            smartPoolTotalDebt += amountBorrow;
            pool.suppliedSP += amountBorrow;
        } else if (newBorrowed > supplied) {
            // this means that it's not "if (newBorrow <= supplied)" in this
            // case we take a little part from smart pool
            smartPoolTotalDebt += amountBorrow - supplied - oldBorrowed;
            pool.suppliedSP += amountBorrow - supplied - oldBorrowed;
        }

        return smartPoolTotalDebt;
    }

    function addFee(
        MaturityPool storage pool,
        uint256 maturityID,
        uint256 commission
    ) internal {
        _accrueAndAddFee(pool, maturityID, commission);
    }

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
