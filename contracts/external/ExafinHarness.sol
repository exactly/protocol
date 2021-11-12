// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/DecimalMath.sol";
import "../utils/ExaLib.sol";

contract ExafinHarness {
    uint256 public totalBorrows;
    uint256 public totalDeposits;

    mapping(address => uint256) public totalDepositUser;
    mapping(address => uint256) public totalBorrowsUser;

    IEToken public eToken;

    function setTotalBorrows(uint _totalBorrows) public {
        totalBorrows = _totalBorrows;
    }

    function setTotalDeposits(uint _totalDeposits) public {
        totalDeposits = _totalDeposits;
    }

    function setTotalBorrowsUser(address _who, uint256 _amount) public {
        totalBorrowsUser[_who] = _amount;
    }

    function setTotalDepositsUser(address _who, uint256 _amount) public {
        totalDepositUser[_who] = _amount;
    }

    function setEToken(address _eTokenAddress) public {
        eToken = IEToken(_eTokenAddress);
    }
}
