// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./IAuditor.sol";

interface IExafin {

    function getRateToSupply(
        uint256 amount,
        uint256 maturityDate
    ) external view returns (uint256);

    function getRateToBorrow(
        uint256 amount,
        uint256 maturityDate
    ) external view returns (uint256);

    function borrow(
        uint256 amount,
        uint256 maturityDate
    ) external;

    function supply(
        address from,
        uint256 amount,
        uint256 maturityDate
    ) external;

    function redeem(
        address payable redeemer,
        uint256 redeemAmount,
        uint256 maturityDate
    ) external;

    function repay(
        address borrower,
        uint256 maturityDate
    ) external;

    function seize(
        address liquidator,
        address borrower,
        uint256 seizeTokens,
        uint256 maturityDate
    ) external;

    function liquidate(
        address borrower,
        uint256 repayAmount,
        IExafin exafinCollateral,
        uint256 maturityDate
    ) external returns (uint256);
    
    function tokenName() external view returns (string calldata);

    function getAccountSnapshot(address who, uint256 timestamp)
        external
        view
        returns (
            uint256,
            uint256
        );

    function getTotalBorrows(uint256 maturityDate)
        external
        view
        returns (uint256);

    function getAuditor() external view returns (IAuditor);
}
