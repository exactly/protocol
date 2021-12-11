// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/math/Math.sol";

library PoolLib {
    struct MaturityPool {
        uint256 borrowed;
        uint256 supplied;
        uint256 debt;
        uint256 available;
    }

    struct SmartPool {
        uint256 borrowed;
        uint256 supplied;
    }

    /**
     * @notice Library Function to manage debt repayment from a maturity pool
     * to the smart pool, if applicable
     * @dev called from repay and deposit functions
     * @param maturity maturity pool to which funds are being deposited
     * @param smart the smart pool of the FixedLender, to which debt might be repaid
     * @param amount size of the repay/deposit
     */
    function repayToSmartPool(
        MaturityPool storage maturity,
        SmartPool storage smart,
        uint256 amount
    ) external {
        if (maturity.debt > 0) {
            // pay all debt to smart pool
            if (amount >= maturity.debt) {
                uint256 changeAfterRepay = amount - maturity.debt;
                maturity.available = changeAfterRepay;
                smart.borrowed -= maturity.debt;
                maturity.debt = 0;
                // pay a fraction of debt to smart pool
            } else {
                maturity.debt -= amount;
                smart.borrowed -= amount;
            }
        } else {
            maturity.available += amount;
        }
    }
}
