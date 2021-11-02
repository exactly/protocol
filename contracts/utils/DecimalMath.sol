// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "hardhat/console.sol";

struct Double {
    uint256 value;
}

library DecimalMath {

    uint256 private constant NUMBER_SCALE = 1e18;
    uint256 private constant DOUBLE_SCALE = 1e36;

    function mul_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b / NUMBER_SCALE;
    }

    function mul_(uint256 a, uint256 b, uint256 scale) internal pure returns (uint256) {
        return a * b / scale;
    }

    function div_(uint256 a, uint256 b, uint256 scale) internal pure returns (uint256) {
        return a * scale / b;
    }

    function div_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * NUMBER_SCALE / b;
    }

    function div_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({value: a.value * DOUBLE_SCALE / b.value});
    }

    function mul_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({value: a.value * b.value / DOUBLE_SCALE});
    }

    function mul_(uint a, Double memory b) internal pure returns (uint) {
        return a * b.value / DOUBLE_SCALE;
    }

    function add_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({value: a.value + b.value});
    }

    function sub_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({value: a.value - b.value});
    }

    function fraction(uint a, uint b) internal pure returns (Double memory) {
        return Double({value: (a * DOUBLE_SCALE / b)});
    }

}
