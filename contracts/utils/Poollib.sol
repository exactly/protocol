// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

library PoolLib {

    struct Pool {
        uint256 borrowed;
        uint256 supplied;
        uint256 debt;
        uint256 available;
    }

    struct SmartPool {
        uint256 borrowed;
        uint256 supplied;
    }
}
