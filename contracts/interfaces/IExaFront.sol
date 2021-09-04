// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IExaFront {
    function getAccountLiquidity(address account, uint256 maturityDate) external view returns (uint, uint, uint);
}
