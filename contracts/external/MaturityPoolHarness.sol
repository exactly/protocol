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
    uint256 public lastCommission;
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

    function fakeDepositToSP(uint256 _amount) external {
        eToken.mint(msg.sender, _amount);
    }

    function fakeWithdrawSP(uint256 _amount) external {
        eToken.burn(msg.sender, _amount);
    }

    function setSmartPoolTotalDebt(uint256 _totalDebt) external {
        smartPoolTotalDebt = _totalDebt;
    }

    function takeMoneyMP(uint256 _amount) external {
        uint256 maxDebt = eToken.totalSupply();
        smartPoolTotalDebt += maturityPool.takeMoney(_amount, maxDebt);
    }

    function addFeeMP(uint256 _maturityID, uint256 _amount) external {
        maturityPool.accrueSP(_maturityID);
        maturityPool.addFee(_amount);
    }

    function addMoneyMP(uint256 _maturityID, uint256 _amount) external {
        maturityPool.accrueSP(_maturityID);

        lastCommission = interestRateModel.getYieldForDeposit(
            maturityPool.suppliedSP,
            maturityPool.unassignedEarnings,
            _amount
        );
        maturityPool.addMoney(_amount + lastCommission);
        maturityPool.takeFee(lastCommission);
    }

    function repayMP(uint256 _maturityID, uint256 _amount) external {
        maturityPool.accrueSP(_maturityID);
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
