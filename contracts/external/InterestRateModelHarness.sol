// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../InterestRateModel.sol";

contract InterestRateModelHarness is InterestRateModel {
    constructor(
        uint256 _curveParameterA,
        int256 _curveParameterB,
        uint256 _maxUtilizationRate,
        uint256 _penaltyRate,
        uint256 _spFeeRate
    )
        InterestRateModel(
            _curveParameterA,
            _curveParameterB,
            _maxUtilizationRate,
            _penaltyRate,
            _spFeeRate
        )
    {}

    function internalGetRateToBorrow(uint256 utilizationRate)
        external
        view
        returns (uint256)
    {
        return getRateToBorrow(utilizationRate);
    }
}
