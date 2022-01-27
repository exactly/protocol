// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/PoolLib.sol";
import "../interfaces/IEToken.sol";
import "../interfaces/IInterestRateModel.sol";

contract MaturityPoolHarness {
    using PoolLib for PoolLib.MaturityPool;

    PoolLib.MaturityPool public maturityPool;
    uint256 public smartPoolTotalDebt;
    IEToken public eToken;
    IInterestRateModel public interestRateModel;
    uint256 public lastFee;
    uint256 public lastEarningsSP;
    uint256 public lastExtrasSP;

    constructor(address _eTokenAddress, address _interestRateModelAddress) {
        eToken = IEToken(_eTokenAddress);
        interestRateModel = IInterestRateModel(_interestRateModelAddress);
    }

    function maxMintEToken() external {
        // it has all the liquidity possible
        eToken.mint(address(this), type(uint256).max);
    }

    function accrueEarningsToSP(uint256 _maturityID) external {
        maturityPool.accrueEarningsToSP(_maturityID);
    }

    function takeMoneyMP(
        uint256 _maturityID,
        uint256 _amount,
        uint256 _feeAmount
    ) external {
        uint256 maxDebt = eToken.totalSupply();
        maturityPool.accrueEarningsToSP(_maturityID);
        smartPoolTotalDebt += maturityPool.takeMoney(_amount, maxDebt);
        maturityPool.addFee(_feeAmount);
    }

    function addMoneyMP(uint256 _maturityID, uint256 _amount) external {
        maturityPool.accrueEarningsToSP(_maturityID);

        lastFee = interestRateModel.getYieldForDeposit(
            maturityPool.suppliedSP,
            maturityPool.unassignedEarnings,
            _amount
        );
        maturityPool.addMoney(_amount);
        maturityPool.takeFee(lastFee);
    }

    function repayMP(uint256 _maturityID, uint256 _amount) external {
        maturityPool.accrueEarningsToSP(_maturityID);
        (
            uint256 smartPoolDebtReduction,
            uint256 earningsSP,
            uint256 extrasSP
        ) = maturityPool.repay(_amount);
        smartPoolTotalDebt -= smartPoolDebtReduction;
        lastEarningsSP = earningsSP;
        lastExtrasSP = extrasSP;
    }
}
