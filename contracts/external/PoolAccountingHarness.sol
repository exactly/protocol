// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../PoolAccounting.sol";
import "../interfaces/IFixedLender.sol";

contract PoolAccountingHarness is PoolAccounting {
    struct ReturnValues {
        uint256 totalOwedNewBorrow;
        uint256 currentTotalDeposit;
        uint256 spareRepayAmount;
        uint256 earningsSP;
        uint256 earningsTreasury;
        uint256 debtCovered;
        uint256 redeemAmountDiscounted;
    }

    ReturnValues public returnValues;
    uint256 public timestamp;

    constructor(address interestRateModel) PoolAccounting(interestRateModel) {
        timestamp = block.timestamp;
    }

    function borrowMPWithReturnValues(
        uint256 maturityDate,
        address borrower,
        uint256 amount,
        uint256 maxAmountAllowed,
        uint256 eTokenTotalSupply,
        uint8 maxFuturePools
    ) external {
        (
            returnValues.totalOwedNewBorrow,
            returnValues.earningsSP,
            returnValues.earningsTreasury
        ) = this.borrowMP(
            maturityDate,
            borrower,
            amount,
            maxAmountAllowed,
            eTokenTotalSupply,
            maxFuturePools
        );
    }

    function depositMPWithReturnValues(
        uint256 maturityDate,
        address supplier,
        uint256 amount,
        uint256 minAmountRequired
    ) external {
        (returnValues.currentTotalDeposit, returnValues.earningsSP) = this
            .depositMP(maturityDate, supplier, amount, minAmountRequired);
    }

    function withdrawMPWithReturnValues(
        uint256 maturityDate,
        address redeemer,
        uint256 amount,
        uint256 minAmountRequired,
        uint256 maxSPDebt
    ) external {
        (
            returnValues.redeemAmountDiscounted,
            returnValues.earningsSP,
            returnValues.earningsTreasury
        ) = this.withdrawMP(
            maturityDate,
            redeemer,
            amount,
            minAmountRequired,
            maxSPDebt
        );
    }

    function repayMPWithReturnValues(
        uint256 maturityDate,
        address borrower,
        uint256 repayAmount,
        uint256 maxAmountAllowed
    ) external {
        (
            returnValues.spareRepayAmount,
            returnValues.debtCovered,
            returnValues.earningsSP,
            returnValues.earningsTreasury
        ) = this.repayMP(maturityDate, borrower, repayAmount, maxAmountAllowed);
    }
}
