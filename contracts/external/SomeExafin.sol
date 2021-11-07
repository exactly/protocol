// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../utils/DecimalMath.sol";
import "../utils/ExaLib.sol";

contract SomeExafin {
    uint256 public totalBorrows;
    uint256 public totalDeposits;
    mapping(address => uint256) public borrowsOf;
    mapping(address => uint256) public suppliesOf;

    function setTotalBorrows(uint _totalBorrows) public {
        totalBorrows = _totalBorrows;
    }

    function setTotalDeposits(uint _totalDeposits) public {
        totalDeposits = _totalDeposits;
    }

    function setBorrowsOf(address _who, uint256 _amount) public {
        borrowsOf[_who] = _amount;
    }

    function setSuppliesOf(address _who, uint256 _amount) public {
        suppliesOf[_who] = _amount;
    }
}
