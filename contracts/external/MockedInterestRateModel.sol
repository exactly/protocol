// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../interfaces/IInterestRateModel.sol";
import "../utils/Errors.sol";
import "../utils/DecimalMath.sol";

contract MockedInterestRateModel is IInterestRateModel {
    using DecimalMath for uint256;

    uint256 public borrowRate;
    uint256 public override penaltyRate;

    function getRateToBorrow(
        uint256 maturityDate,
        uint256 currentDate,
        uint256 borrowedMP,
        uint256 suppliedMP,
        uint256 borrowableFromSP
    ) external view override returns (uint256) {
        return borrowRate;
    }

    function getYieldForDeposit(
        uint256 suppliedSP,
        uint256 unassignedEarnings,
        uint256 amount,
        uint256 mpDepositDistributionWeighter
    ) external pure override returns (uint256 earningsShare) {
        amount = amount.mul_(mpDepositDistributionWeighter);
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
