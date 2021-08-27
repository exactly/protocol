// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface Oracle {
    function price(string memory symbol) external view returns (uint); // use 0x6d2299c48a8dd07a872fdd0f8233924872ad1071
}
