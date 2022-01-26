// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../interfaces/IInterestRateModel.sol";
import "../utils/TSUtils.sol";
import "../utils/Errors.sol";
import "../utils/DecimalMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract MockedInterestRateModel is IInterestRateModel {
    uint256 public borrowRate;
    uint256 public override penaltyRate;

    function getRateToBorrow(
        uint256,
        PoolLib.MaturityPool memory,
        uint256,
        uint256,
        bool
    ) external view override returns (uint256) {
        return borrowRate;
    }

    function getYieldForDeposit(
        uint256 suppliedSP,
        uint256 unassignedEarnings,
        uint256 amount
    ) external pure override returns (uint256 earningsShare) {
        uint256 supply = suppliedSP + amount;
        earningsShare = supply == 0
            ? 0
            : (amount * unassignedEarnings) / supply;
    }

    function setBorrowRate(uint256 newRate) public {
        borrowRate = newRate;
    }

    function setPenaltyRate(uint256 newRate) public {
        penaltyRate = newRate;
    }
}
