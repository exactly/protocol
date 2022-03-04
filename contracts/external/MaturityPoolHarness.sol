// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/PoolLib.sol";
import "../interfaces/IEToken.sol";
import "../interfaces/IInterestRateModel.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract MaturityPoolHarness {
    using PoolLib for PoolLib.MaturityPool;
    using PoolLib for PoolLib.Position;

    PoolLib.MaturityPool public maturityPool;
    uint256 public newDebtSP;
    uint256 public smartPoolDebtReduction;
    uint256 public nextTimestamp;
    uint256 public lastEarningsSP;
    PoolLib.Position public scaledDebt;

    function accrueEarnings(uint256 _maturityID) external {
        lastEarningsSP = maturityPool.accrueEarnings(
            _maturityID,
            nextTimestamp != 0 ? nextTimestamp : block.timestamp
        );
    }

    function depositMoney(uint256 _amount) external {
        smartPoolDebtReduction = maturityPool.depositMoney(_amount);
    }

    function repayMoney(uint256 _amount) external {
        smartPoolDebtReduction = maturityPool.repayMoney(_amount);
    }

    function borrowMoney(uint256 _amount, uint256 _maxDebt) external {
        newDebtSP = maturityPool.borrowMoney(_amount, _maxDebt);
    }

    function withdrawMoney(
        uint256 _amountToDiscount,
        uint256 _amountToGive,
        uint256 _maxDebt
    ) external {
        newDebtSP = maturityPool.withdrawMoney(
            _amountToDiscount,
            _amountToGive,
            _maxDebt
        );
    }

    function addFee(uint256 _fee) external {
        maturityPool.addFee(_fee);
    }

    function removeFee(uint256 _fee) external {
        maturityPool.removeFee(_fee);
    }

    function scaleProportionally(
        uint256 _scaledDebtPrincipal,
        uint256 _scaledDebtFee,
        uint256 _amount
    ) external {
        scaledDebt.principal = _scaledDebtPrincipal;
        scaledDebt.fee = _scaledDebtFee;
        scaledDebt = scaledDebt.scaleProportionally(_amount);
    }

    function reduceProportionally(
        uint256 _scaledDebtPrincipal,
        uint256 _scaledDebtFee,
        uint256 _amount
    ) external {
        scaledDebt.principal = _scaledDebtPrincipal;
        scaledDebt.fee = _scaledDebtFee;
        scaledDebt = scaledDebt.reduceProportionally(_amount);
    }

    function setNextTimestamp(uint256 _nextTimestamp) external {
        nextTimestamp = _nextTimestamp;
    }
}
