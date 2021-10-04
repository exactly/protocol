// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "../utils/Poollib.sol";

interface IInterestRateModel {

    function rateToBorrow(
        uint256 amount,
        uint256 maturityDate,
        Poollib.Pool memory poolMaturity,
        Poollib.Pool memory poolPot
    ) external view returns (uint256);

    function rateForSupply(
        uint256 amount,
        uint256 maturityDate,
        Poollib.Pool memory poolMaturity,
        Poollib.Pool memory poolPot
    ) external view returns (uint256);
 
}