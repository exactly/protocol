// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;
import "../utils/TSUtils.sol";

interface IAuditor {
    function beforeSupplySmartPool(
        address fixedLenderAddress,
        address supplier
    ) external;

    function beforeWithdrawSmartPool(
        address fixedLenderAddress,
        address supplier
    ) external;

    function beforeDepositMaturityPool(
        address fixedLenderAddress,
        address borrower,
        uint256 maturityDate
    ) external;

    function beforeBorrowMaturityPool(
        address fixedLenderAddress,
        address borrower,
        uint256 borrowAmount,
        uint256 maturityDate
    ) external;

    function beforeWithdrawMaturityPool(
        address fixedLenderAddress,
        address redeemer,
        uint256 redeemTokens,
        uint256 maturityDate
    ) external;

    function beforeRepayMaturityPool(
        address fixedLenderAddress,
        address borrower
    ) external;

    function getAccountLiquidity(
        address account,
        uint256 maturityDate
    ) external view returns (uint256, uint256);

    function liquidateAllowed(
        address fixedLenderBorrowed,
        address fixedLenderCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount, 
        uint256 maturityDate
    ) external view;

    function seizeAllowed(
        address fixedLenderCollateral,
        address fixedLenderBorrowed,
        address liquidator,
        address borrower
    ) external view;

    function liquidateCalculateSeizeAmount(
        address fixedLenderBorrowed,
        address fixedLenderCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256);

    function getFuturePools() external view returns (uint256[] memory);
    function getMarketAddresses() external view returns (address[] memory);

    function requirePoolState(uint256 maturityDate, TSUtils.State requiredState) external view;

}
