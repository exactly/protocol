// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { FixedLender } from "../FixedLender.sol";

interface IAuditor {
  // this one validates post liquidity check
  function validateBorrowMP(FixedLender fixedLender, address borrower) external;

  function getAccountLiquidity(address account) external view returns (uint256, uint256);

  function liquidateAllowed(
    FixedLender fixedLenderBorrowed,
    FixedLender fixedLenderCollateral,
    address liquidator,
    address borrower
  ) external view;

  function seizeAllowed(
    FixedLender fixedLenderCollateral,
    FixedLender fixedLenderBorrowed,
    address liquidator,
    address borrower
  ) external view;

  function liquidateCalculateSeizeAmount(
    FixedLender fixedLenderBorrowed,
    FixedLender fixedLenderCollateral,
    uint256 actualRepayAmount
  ) external view returns (uint256);

  function getAllMarkets() external view returns (FixedLender[] memory);

  function validateAccountShortfall(
    FixedLender fixedLender,
    address account,
    uint256 amount
  ) external view;
}

error AuditorMismatch();
error BalanceOwed();
error BorrowCapReached();
error InsufficientLiquidity();
error InsufficientShortfall();
error InvalidParameter();
error LiquidatorNotBorrower();
error MarketAlreadyListed();
error MarketNotListed();
error TooMuchRepay();
