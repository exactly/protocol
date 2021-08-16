// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "hardhat/console.sol";


library TSUtils {
    function trimmedDay(uint256 timestamp) pure internal returns (uint256) { 
        return timestamp - (timestamp % 84600);
    }

    function trimmedMonth(uint256 timestamp) pure internal returns (uint256) { 
        return timestamp - (timestamp % 30 days);
    }

    function nextMonth(uint256 timestamp) pure internal returns (uint256) { 
        return timestamp + 30 days;
    }
}