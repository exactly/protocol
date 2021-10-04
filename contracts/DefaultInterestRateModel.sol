// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/IInterestRateModel.sol";
import "./utils/TSUtils.sol";
import "./utils/Poollib.sol";

contract DefaultInterestRateModel is IInterestRateModel {
    using Poollib for Poollib.Pool;

    uint256 public marginRate;
    uint256 public slopeRate;

    constructor(uint256 _marginRate, uint256 _slopeRate) {
        marginRate = _marginRate;
        slopeRate = _slopeRate;
    }

    function rateToBorrow(
        uint256 amount,
        uint256 maturityDate,
        Poollib.Pool memory poolMaturity,
        Poollib.Pool memory poolPot
    ) override public view returns (uint256) {
        require(TSUtils.isPoolID(maturityDate) == true, "Not a pool ID");
        require(block.timestamp < maturityDate, "Pool Matured");

        poolMaturity.borrowed += amount;

        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;
        uint256 yearlyRate = marginRate +
            ((slopeRate * poolMaturity.borrowed) / poolMaturity.supplied);

        return ((yearlyRate * daysDifference) / 365);

    }

    function rateForSupply(
        uint256 amount,
        uint256 maturityDate,
        Poollib.Pool memory poolMaturity,
        Poollib.Pool memory poolPot
    ) override public view returns (uint256) {
        require(TSUtils.isPoolID(maturityDate) == true, "Not a pool ID");
        require(block.timestamp < maturityDate, "Pool Matured");
        require(amount != 0, "Can't supply zero");

        poolMaturity.supplied += amount;

        uint256 daysDifference = (maturityDate -
            TSUtils.trimmedDay(block.timestamp)) / 1 days;

        uint256 yearlyRate = ((slopeRate * poolMaturity.borrowed) / poolMaturity.supplied);

        return ((yearlyRate * daysDifference) / 365);
    }

}
