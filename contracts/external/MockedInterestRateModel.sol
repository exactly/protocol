// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../interfaces/IInterestRateModel.sol";
import "../utils/TSUtils.sol";
import "../utils/Errors.sol";
import "../utils/DecimalMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract MockedInterestRateModel is IInterestRateModel {
    uint256 public supplyRate;
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

    function setSupplyRate(uint256 newRate) public {
        supplyRate = newRate;
    }

    function setBorrowRate(uint256 newRate) public {
        borrowRate = newRate;
    }

    function setPenaltyRate(uint256 newRate) public {
        penaltyRate = newRate;
    }
}
