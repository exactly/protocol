// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IAuditor {
    function getAccountLiquidity(address account, uint256 maturityDate) external view returns (uint, uint, uint);
    function borrowAllowed(address exafinAddress, address borrower, uint borrowAmount, uint maturityDate) external returns (uint);
    function redeemAllowed(address exafinAddress, address redeemer, uint redeemTokens, uint maturityDate) external view returns (uint);
    function repayAllowed(address exafinAddress, address borrower, uint repayAmount) external returns (uint);
}
