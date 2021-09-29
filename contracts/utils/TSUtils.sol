// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "hardhat/console.sol";


library TSUtils {
    function trimmedDay(uint256 timestamp) internal pure returns (uint256) { 
        return timestamp - (timestamp % 86400);
    }

    function isPoolID(uint256 timestamp) internal pure returns (bool) {
        return (timestamp % 14 days) == 0;
    }
}
