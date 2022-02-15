// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../interfaces/IInterestRateModel.sol";
import "../utils/Errors.sol";
import "../utils/DecimalMath.sol";

contract MockedInterestRateModel is IInterestRateModel {
    using DecimalMath for uint256;

    uint256 public borrowRate;
    uint256 public override penaltyRate;
    uint256 public spFeeRate;
    IInterestRateModel public realInterestRateModel;

    constructor(address _realInterestRateModel) {
        realInterestRateModel = IInterestRateModel(_realInterestRateModel);
    }

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
        uint256 borrowed,
        uint256 unassignedEarnings,
        uint256 amount
    )
        external
        view
        override
        returns (uint256 earningsShare, uint256 earningsShareSP)
    {
        // we call the real implementation since it has a certain specific logic
        // that makes the whole system stable
        return
            realInterestRateModel.getYieldForDeposit(
                suppliedSP,
                borrowed,
                unassignedEarnings,
                amount
            );
    }

    function setBorrowRate(uint256 newRate) public {
        borrowRate = newRate;
    }

    function setSPFeeRate(uint256 newRate) public {
        spFeeRate = newRate;
    }

    function setPenaltyRate(uint256 newRate) public {
        penaltyRate = newRate;
    }
}
