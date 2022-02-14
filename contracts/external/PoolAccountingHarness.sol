// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../interfaces/IPoolAccounting.sol";
import "../interfaces/IFixedLender.sol";

contract PoolAccountingHarness {
    struct ReturnValues {
        uint256 totalOwedNewBorrow;
        uint256 currentTotalDeposit;
        uint256 penalties;
        uint256 debtCovered;
        uint256 fee;
        uint256 earningsRepay;
    }

    ReturnValues public returnValues;
    IPoolAccounting public poolAccounting;
    IFixedLender public fixedLender;

    constructor(address _poolAccounting, address _fixedLender) {
        poolAccounting = IPoolAccounting(_poolAccounting);
        fixedLender = IFixedLender(_fixedLender);
    }

    function borrowMP(
        uint256 maturityDate,
        address borrower,
        uint256 amount,
        uint256 maxAmountAllowed,
        uint256 maxSPDebt
    ) external {
        returnValues.totalOwedNewBorrow = poolAccounting.borrowMP(
            maturityDate,
            borrower,
            amount,
            maxAmountAllowed,
            maxSPDebt
        );
    }

    function depositMP(
        uint256 maturityDate,
        address supplier,
        uint256 amount,
        uint256 minAmountRequired
    ) external {
        returnValues.currentTotalDeposit = poolAccounting.depositMP(
            maturityDate,
            supplier,
            amount,
            minAmountRequired
        );
    }

    function withdrawMP(
        uint256 maturityDate,
        address redeemer,
        uint256 amount,
        uint256 maxSPDebt
    ) external {
        poolAccounting.withdrawMP(maturityDate, redeemer, amount, maxSPDebt);
    }

    function repayMP(
        uint256 maturityDate,
        address borrower,
        uint256 repayAmount
    ) external {
        (
            returnValues.penalties,
            returnValues.debtCovered,
            returnValues.fee,
            returnValues.earningsRepay
        ) = poolAccounting.repayMP(maturityDate, borrower, repayAmount);
    }

    function mpDepositDistributionWeighter() external view returns (uint256) {
        return fixedLender.mpDepositDistributionWeighter();
    }
}
