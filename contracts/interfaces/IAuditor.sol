// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IAuditor {

    function getAccountLiquidity(
        address account,
        uint256 maturityDate
    ) external view returns (uint256, uint256, uint256);

    function supplyAllowed(
        address exafinAddress,
        address borrower,
        uint256 borrowAmount,
        uint256 maturityDate
    ) external returns (uint256);

    function borrowAllowed(
        address exafinAddress,
        address borrower,
        uint256 borrowAmount,
        uint256 maturityDate
    ) external returns (uint256);

    function redeemAllowed(
        address exafinAddress,
        address redeemer,
        uint256 redeemTokens,
        uint256 maturityDate
    ) external view returns (uint256);

    function repayAllowed(
        address exafinAddress,
        address borrower,
        uint256 repayAmount,
        uint256 maturityDate
    ) external returns (uint256);

}
