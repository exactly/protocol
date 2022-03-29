// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { MockToken } from "./MockToken.sol";
import { IFixedLender } from "../interfaces/IFixedLender.sol";
import { IFlashBorrower } from "./IFlashBorrower.sol";

contract FlashLoanAttacker is IFlashBorrower {
  MockToken private underlying;
  IFixedLender private fixedLender;
  uint256 private maturityDate;
  uint256 private amount;
  address private borrower;
  uint256 private constant FLASHLOAN_AMOUNT = 1e9 ether;

  function attack(
    IFixedLender fixedLender_,
    uint256 maturityDate_,
    uint256 amount_
  ) external {
    borrower = msg.sender;
    maturityDate = maturityDate_;
    fixedLender = fixedLender_;
    amount = amount_;
    underlying = MockToken(address(fixedLender.trustedUnderlying()));
    underlying.flashLoan(FLASHLOAN_AMOUNT);
  }

  function doThingsWithFlashLoan() external override {
    underlying.approve(address(fixedLender), 2 * FLASHLOAN_AMOUNT);
    fixedLender.depositToSmartPool(FLASHLOAN_AMOUNT);
    fixedLender.repayToMaturityPool(borrower, maturityDate, amount, amount);
    fixedLender.withdrawFromSmartPool(FLASHLOAN_AMOUNT);
  }
}
