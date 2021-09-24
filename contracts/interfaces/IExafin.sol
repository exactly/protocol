// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./IAuditor.sol";

struct Pool {
    uint256 borrowed;
    uint256 supplied;
}

interface IExafin {
    function rateForSupply(uint256 amount, uint256 maturityDate)
        external
        view
        returns (uint256, Pool memory);

    function rateToBorrow(uint256 amount, uint256 maturityDate)
        external
        view
        returns (uint256, Pool memory);

    function borrow(
        address to,
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
        uint256 repayAmount,
        uint256 maturityDate
    ) external;
    
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
