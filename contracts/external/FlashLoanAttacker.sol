// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./MockedToken.sol";
import "./IFlashBorrower.sol";
import "../interfaces/IFixedLender.sol";

contract FlashLoanAttacker is IFlashBorrower {
    MockedToken private underlying;
    IFixedLender private fixedLender;
    uint256 private maturityDate;
    address private borrower;
    uint256 constant FLASHLOAN_AMOUNT = 1e9 ether;

    function attack(IFixedLender fixedLender_, uint256 maturityDate_) external {
        borrower = msg.sender;
        maturityDate = maturityDate_;
        fixedLender = fixedLender_;
        underlying = MockedToken(address(fixedLender.trustedUnderlying()));
        underlying.flashLoan(FLASHLOAN_AMOUNT);
    }

    function doThingsWithFlashLoan() external override {
        underlying.approve(address(fixedLender), 2 * FLASHLOAN_AMOUNT);
        fixedLender.depositToSmartPool(FLASHLOAN_AMOUNT);
        fixedLender.repayToMaturityPool(borrower, maturityDate);
        fixedLender.withdrawFromSmartPool(FLASHLOAN_AMOUNT);
    }
}
