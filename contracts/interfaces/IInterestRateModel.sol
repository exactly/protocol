// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/PoolLib.sol";

interface IInterestRateModel {
    function getRateToBorrow(
        uint256 maturityDate,
        PoolLib.MaturityPool memory poolMaturity,
        uint256 smartPoolTotalDebt,
        uint256 smartPoolTotalSupply,
        bool newDebt
    ) external view returns (uint256);

    function penaltyRate() external view returns (uint256);

    function getYieldForDeposit(
        uint256 suppliedSP,
        uint256 unassignedEarnings,
        uint256 amount,
        uint256 mpDepositDistributionWeighter
    ) external pure returns (uint256 earningsShare);
}
