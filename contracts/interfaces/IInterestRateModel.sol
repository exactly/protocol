// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/PoolLib.sol";

interface IInterestRateModel {
    function getRateToBorrow(
        uint256 maturityDate,
        uint256 currentDate,
        uint256 borrowedMP,
        uint256 suppliedMP,
        uint256 borrowableFromSP
    ) external view returns (uint256);

    function penaltyRate() external view returns (uint256);
}
