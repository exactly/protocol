// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/Poollib.sol";

interface IInterestRateModel {
    function getRateToBorrow(
        uint256 maturityDate,
        PoolLib.MaturityPool memory poolMaturity,
        PoolLib.SmartPool memory smartPool,
        bool newDebt
    ) external view returns (uint256);

    function getRateToSupply(
        uint256 maturityDate,
        PoolLib.MaturityPool memory poolMaturity
    ) external view returns (uint256);

    function penaltyRate() external view returns (uint256);

}
