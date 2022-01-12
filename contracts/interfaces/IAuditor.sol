// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;
import "../utils/TSUtils.sol";

interface IAuditor {
    function beforeDepositSP(address fixedLenderAddress, address supplier)
        external;

    function beforeWithdrawSP(
        address fixedLenderAddress,
        address redeemer,
        uint256 redeemAmount
    ) external;

    function beforeDepositMP(
        address fixedLenderAddress,
        address supplier,
        uint256 maturityDate
    ) external;

    function beforeTransferSP(
        address fixedLenderAddress,
        address sender,
        address recipient,
        uint256 amount
    ) external;

    function beforeBorrowMP(
        address fixedLenderAddress,
        address borrower,
        uint256 borrowAmount,
        uint256 maturityDate
    ) external;

    function beforeWithdrawMP(
        address fixedLenderAddress,
        address redeemer,
        uint256 maturityDate
    ) external;

    function beforeRepayMP(
        address fixedLenderAddress,
        address borrower,
        uint256 maturityDate
    ) external;

    function getAccountLiquidity(address account)
        external
        view
        returns (uint256, uint256);

    function liquidateAllowed(
        address fixedLenderBorrowed,
        address fixedLenderCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
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

    function maxFuturePools() external view returns (uint8);

    function getMarketAddresses() external view returns (address[] memory);

    function requirePoolState(uint256 maturityDate, TSUtils.State requiredState)
        external
        view;
}
