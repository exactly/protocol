// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/DecimalMath.sol";
import "../utils/ExaLib.sol";

contract FixedLenderHarness {
    uint256 public totalBorrows;
    uint256 public totalDeposits;

    mapping(address => uint256) public totalDepositsUser;
    mapping(address => uint256) public totalBorrowsUser;

    IEToken public eToken;

    function setTotalBorrows(uint256 _totalBorrows) public {
        totalBorrows = _totalBorrows;
    }

    function setTotalDeposits(uint256 _totalDeposits) public {
        totalDeposits = _totalDeposits;
    }

    function setTotalBorrowsUser(address _who, uint256 _amount) public {
        totalBorrowsUser[_who] = _amount;
    }

    function setTotalDepositsUser(address _who, uint256 _amount) public {
        totalDepositsUser[_who] = _amount;
    }

    function setTotalSmartPoolDeposits(address _who, uint256 _totalDeposits) public {
        eToken.mint(_who, _totalDeposits);
    }

    function setEToken(address _eTokenAddress) public {
        eToken = IEToken(_eTokenAddress);
    }
}
