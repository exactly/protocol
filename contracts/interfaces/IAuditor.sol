// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

interface IAuditor {

    function getAccountLiquidity(
        address account,
        uint256 maturityDate
    ) external view returns (uint256, uint256);

    function supplyAllowed(
        address exafinAddress,
        address borrower,
        uint256 borrowAmount,
        uint256 maturityDate
    ) external;

    function borrowAllowed(
        address exafinAddress,
        address borrower,
        uint256 borrowAmount,
        uint256 maturityDate
    ) external;

    function redeemAllowed(
        address exafinAddress,
        address redeemer,
        uint256 redeemTokens,
        uint256 maturityDate
    ) external;

    function repayAllowed(
        address exafinAddress,
        address borrower,
        uint256 maturityDate
    ) external;

    function liquidateAllowed(
        address exafinBorrowed,
        address exafinCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount, 
        uint256 maturityDate
    ) external view;

    function seizeAllowed(
        address exafinCollateral,
        address exafinBorrowed,
        address liquidator,
        address borrower
    ) external view;

    function liquidateCalculateSeizeAmount(
        address exafinBorrowed,
        address exafinCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256);

    function getFuturePools() external view returns (uint256[] memory);
    function getMarketAddresses() external view returns (address[] memory);

}
