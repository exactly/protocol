// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../interfaces/IPoolAccounting.sol";

contract PoolAccountingHarness {
    struct ReturnValues {
        uint256 totalOwedNewBorrow;
        uint256 currentTotalDeposit;
        uint256 currentTotalWithdrawal;
        uint256 spareAmount;
        uint256 debtCovered;
        uint256 fee;
        uint256 earningsRepay;
    }

    ReturnValues public returnValues;
    IPoolAccounting public poolAccounting;

    constructor(address _poolAccounting) {
        poolAccounting = IPoolAccounting(_poolAccounting);
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
        uint256 minAmountRequired,
        uint256 maxSPDebt
    ) external {
        returnValues.currentTotalWithdrawal = poolAccounting.withdrawMP(
            maturityDate,
            redeemer,
            amount,
            minAmountRequired,
            maxSPDebt
        );
    }

    function repayMP(
        uint256 maturityDate,
        address borrower,
        uint256 repayAmount,
        uint256 maxAmountAllowed
    ) external {
        (
            returnValues.spareAmount,
            returnValues.debtCovered,
            returnValues.fee,
            returnValues.earningsRepay
        ) = poolAccounting.repayMP(
            maturityDate,
            borrower,
            repayAmount,
            maxAmountAllowed
        );
    }
}
