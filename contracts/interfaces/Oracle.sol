// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface Oracle {
    function price(string memory symbol) external view returns (uint);
}
