// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/PoolLib.sol";
import "../interfaces/IEToken.sol";
import "../interfaces/IInterestRateModel.sol";

contract MaturityPoolHarness {
    using PoolLib for PoolLib.MaturityPool;

    PoolLib.MaturityPool public maturityPool;

    function accrueEarnings(uint256 _maturityID) external {
        maturityPool.accrueEarnings(_maturityID);
    }

    function addMoney(uint256 _amount) external {
        maturityPool.addMoney(_amount);
    }

    function addFeeMP(uint256 _fee) external {
        maturityPool.addFeeMP(_fee);
    }
}
