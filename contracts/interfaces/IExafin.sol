// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

struct Pool {
    uint256 borrowed;
    uint256 lent;
}

interface IExafin {
    function rateForSupply(uint256 amount, uint256 maturityDate) external view returns (uint256, Pool memory);
    function rateToBorrow(uint256 amount, uint256 maturityDate) external view returns (uint256, Pool memory);
    function borrow(address to, uint256 amount, uint256 maturityDate) external;
    function supply(address from, uint256 amount, uint256 maturityDate) external;
    function tokenName() external view returns (string calldata);
    function getAccountSnapshot(address who, uint timestamp) external view returns (uint, uint, uint);
    function getTotalBorrows(uint256 maturityDate) external view returns (uint);
}
