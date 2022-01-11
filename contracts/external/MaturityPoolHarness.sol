// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/PoolLib.sol";
import "../interfaces/IEToken.sol";

contract MaturityPoolHarness {
    using PoolLib for PoolLib.MaturityPool;

    PoolLib.MaturityPool public maturityPool;
    uint256 public smartPoolTotalDebt;
    IEToken public eToken;
    uint256 public lastCommission;

    constructor(address _eTokenAddress) {
        eToken = IEToken(_eTokenAddress);
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
        maturityPool.addFee(_maturityID, _amount);
    }

    function addMoneyMP(uint256 _maturityID, uint256 _amount) external {
        lastCommission = maturityPool.addMoney(_maturityID, _amount);
    }
}
