// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/DecimalMath.sol";
import "../utils/ExaLib.sol";

contract FixedLenderHarness {
    uint256 public totalMpBorrows;
    uint256 public totalMpDeposits;

    mapping(address => uint256) public totalMpDepositsUser;
    mapping(address => uint256) public totalMpBorrowsUser;

    IEToken public eToken;

    function setTotalMpBorrows(uint256 _totalMpBorrows) public {
        totalMpBorrows = _totalMpBorrows;
    }

    function setTotalMpDeposits(uint256 _totalMpDeposits) public {
        totalMpDeposits = _totalMpDeposits;
    }

    function setTotalMpBorrowsUser(address _who, uint256 _amount) public {
        totalMpBorrowsUser[_who] = _amount;
    }

    function setTotalMpDepositsUser(address _who, uint256 _amount) public {
        totalMpDepositsUser[_who] = _amount;
    }

    function setTotalSpDeposits(address _who, uint256 _totalSpDeposits) public {
        eToken.mint(_who, _totalSpDeposits);
    }

    function setEToken(address _eTokenAddress) public {
        eToken = IEToken(_eTokenAddress);
    }
}
