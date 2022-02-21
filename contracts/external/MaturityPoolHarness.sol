// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/PoolLib.sol";
import "../interfaces/IEToken.sol";
import "../interfaces/IInterestRateModel.sol";

contract MaturityPoolHarness {
    using PoolLib for PoolLib.MaturityPool;
    using PoolLib for PoolLib.Debt;

    PoolLib.MaturityPool public maturityPool;
    uint256 public newDebtSP;
    uint256 public smartPoolDebtReduction;
    PoolLib.Debt public scaledDebt;

    function accrueEarnings(uint256 _maturityID) external {
        // TODO: convert block.number to a state variable to have
        // more control over the tests
        maturityPool.accrueEarnings(_maturityID, block.number);
    }

    function addMoney(uint256 _amount) external {
        smartPoolDebtReduction = maturityPool.addMoney(_amount);
    }

    function repayMoney(uint256 _amount) external {
        smartPoolDebtReduction = maturityPool.repayMoney(_amount);
    }

    function takeMoney(uint256 _amount, uint256 _maxDebt) external {
        newDebtSP = maturityPool.takeMoney(_amount, _maxDebt);
    }

    function withdrawMoney(uint256 _amount, uint256 _maxDebt) external {
        newDebtSP = maturityPool.withdrawMoney(_amount, _maxDebt);
    }

    function addFeeSP(uint256 _fee) external {
        maturityPool.addFeeSP(_fee);
    }

    function addFeeMP(uint256 _fee) external {
        maturityPool.addFeeMP(_fee);
    }

    function addFee(uint256 _fee) external {
        maturityPool.addFee(_fee);
    }

    function removeFee(uint256 _fee) external {
        maturityPool.removeFee(_fee);
    }

    function returnFee(uint256 _fee) external {
        maturityPool.returnFee(_fee);
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

    function reduceFee(uint256 _scaledDebtFee, uint256 _feeToReduce) external {
        scaledDebt.fee = _scaledDebtFee;
        scaledDebt = scaledDebt.reduceFees(_feeToReduce);
    }
}
