// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "hardhat/console.sol";

library DecimalMath {

    uint private constant NUMBER_SCALE = 1e18;

    function mul_(uint a, uint b) internal pure returns (uint) {
        return a * b / NUMBER_SCALE;
    }

    function mul_(uint a, uint b, uint scale) internal pure returns (uint) {
        return a * b / scale;
    }
}