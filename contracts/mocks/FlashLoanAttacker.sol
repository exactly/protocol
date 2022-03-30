// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { MockToken } from "./MockToken.sol";
import { FixedLender } from "../FixedLender.sol";
import { IFlashBorrower } from "./IFlashBorrower.sol";

contract FlashLoanAttacker is IFlashBorrower {
  MockToken private underlying;
  FixedLender private fixedLender;
  uint256 private maturityDate;
  uint256 private amount;
  address private borrower;
  uint256 private constant FLASHLOAN_AMOUNT = 1e9 ether;

  function attack(
    FixedLender fixedLender_,
    uint256 maturityDate_,
    uint256 amount_
  ) external {
    borrower = msg.sender;
    maturityDate = maturityDate_;
    fixedLender = fixedLender_;
    amount = amount_;
    underlying = MockToken(address(fixedLender.asset()));
    underlying.flashLoan(FLASHLOAN_AMOUNT);
  }

  function doThingsWithFlashLoan() external override {
    underlying.approve(address(fixedLender), 2 * FLASHLOAN_AMOUNT);
    fixedLender.deposit(FLASHLOAN_AMOUNT, address(this));
    fixedLender.repayToMaturityPool(borrower, maturityDate, amount, amount);
    fixedLender.withdraw(FLASHLOAN_AMOUNT, address(this), address(this));
  }
}
