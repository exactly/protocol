// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../PoolAccounting.sol";
import "../interfaces/IFixedLender.sol";
import "hardhat/console.sol";

contract PoolAccountingHarness is PoolAccounting {
    struct ReturnValues {
        uint256 totalOwedNewBorrow;
        uint256 currentTotalDeposit;
        uint256 currentTotalWithdrawal;
        uint256 spareAmount;
        uint256 earningsSP;
        uint256 earningsTreasury;
        uint256 debtCovered;
    }

    ReturnValues public returnValues;
    uint256 public timestamp;
    IFixedLender public fixedLender;

    constructor(address interestRateModel, address fixedLenderAddress)
        PoolAccounting(interestRateModel)
    {
        timestamp = block.timestamp;
        fixedLender = IFixedLender(fixedLenderAddress);
    }

    function borrowMPWithReturnValues(
        uint256 maturityDate,
        address borrower,
        uint256 amount,
        uint256 maxAmountAllowed,
        uint256 maxSPDebt
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
            maxSPDebt
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
            returnValues.currentTotalWithdrawal,
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
            returnValues.spareAmount,
            returnValues.debtCovered,
            returnValues.earningsSP
        ) = this.repayMP(maturityDate, borrower, repayAmount, maxAmountAllowed);
    }

    function setCurrentTimestamp(uint256 _timestamp) external {
        timestamp = _timestamp;
    }

    function mpDepositDistributionWeighter() external view returns (uint256) {
        return fixedLender.mpDepositDistributionWeighter();
    }

    function currentTimestamp() internal view override returns (uint256) {
        return timestamp;
    }
}
