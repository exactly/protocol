// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { IFixedLender } from "./IFixedLender.sol";

interface IAuditor {
  // this one validates post liquidity check
  function validateBorrowMP(IFixedLender fixedLender, address borrower) external;

  function getAccountLiquidity(address account) external view returns (uint256, uint256);

  function liquidateAllowed(
    IFixedLender fixedLenderBorrowed,
    IFixedLender fixedLenderCollateral,
    address liquidator,
    address borrower,
    uint256 repayAmount
  ) external view;

  function seizeAllowed(
    IFixedLender fixedLenderCollateral,
    IFixedLender fixedLenderBorrowed,
    address liquidator,
    address borrower
  ) external view;

  function liquidateCalculateSeizeAmount(
    IFixedLender fixedLenderBorrowed,
    IFixedLender fixedLenderCollateral,
    uint256 actualRepayAmount
  ) external view returns (uint256);

  function getAllMarkets() external view returns (IFixedLender[] memory);

  function validateAccountShortfall(
    IFixedLender fixedLender,
    address account,
    uint256 amount
  ) external view;
}

error AuditorMismatch();
error BalanceOwed();
error BorrowCapReached();
error InsufficientLiquidity();
error InsufficientShortfall();
error InvalidBorrowCaps();
error LiquidatorNotBorrower();
error MarketAlreadyListed();
error MarketNotListed();
error TooMuchRepay();
